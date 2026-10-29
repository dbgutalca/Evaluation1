package com.map;

import org.mapdb.*;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Consumer;

public class Main implements AutoCloseable {

    private static final String DB_FILE_NAME = "graph.db";
    
    // Batch sizes
    private static final int NODE_BATCH = 50_000;
    private static final int EDGE_BATCH = 100_000;

    private static final String MAP_NODES = "map_nodes";
    private static final String MAP_EDGES = "map_edges";

    private static final String IDX_EDGEIDS_BY_LABEL = "idx_edgeids_by_label";
    private static final String IDX_NODES_BY_PROP    = "idx_nodes_by_prop";

    private static final String HI_SENTINEL = "\uFFFF";

    private final DB db;
    private final HTreeMap<String, NodeBlob> nodes;
    private final HTreeMap<String, EdgeBlob> edges;
    private final NavigableSet<KeyTuple> idxEdgeIdsByLabel;
    private final NavigableSet<KeyTuple> idxNodesByProp;

    public static void main(String[] args) throws Exception {
        if (args.length < 1) usage();

        if (args.length >= 2 && ("ingest".equals(args[0]) || "bench".equals(args[0]))) {
            Path configPath = Path.of(args[1]).toAbsolutePath();
            Path baseDir = configPath.getParent();
            Properties cfg = loadConfig(configPath.toString());
            Path dbPath = resolvePath(baseDir, cfg.getProperty("mapdb_dir", "dbs/mapdb"));
            try (Main store = Main.open(dbPath)) {
                if ("ingest".equals(args[0])) {
                    Path nodes = resolvePath(baseDir, cfg.getProperty("nodes_path"));
                    Path edges = resolvePath(baseDir, cfg.getProperty("edges_path"));
                    String sf = cfg.getProperty("scale_factor", "");
                    Path resultsDir = resolvePath(baseDir, cfg.getProperty("results_dir", "results"));
                    store.runIngest(nodes, edges, sf, resultsDir);
                } else {
                    String overrideCondition = args.length >= 3 ? args[2] : null;
                    Integer overrideRep = args.length >= 4 ? Integer.parseInt(args[3]) : null;
                    store.runBenchmarkConfig(cfg, baseDir, overrideCondition, overrideRep);
                }
            }
            return;
        }

        if (Objects.equals(args[0], "ingest")) {
            if (args.length < 4) usage();
            Path nodes = Path.of(args[1]);
            Path edges = Path.of(args[2]);
            Path dbPath = Path.of(args[3]);

            try (Main store = Main.open(dbPath)) {
                store.runIngest(nodes, edges);
            }
            return;
        }

        if (args.length < 2) usage();
        Path dbPath = Path.of(args[0]);
        String flag = args[1];

        try (Main store = Main.open(dbPath)) {
            switch (flag) {
                case "bench" -> {
                    if (args.length < 5) usage();
                    Path idsPath = Path.of(args[2]);
                    Path labelsPath = Path.of(args[3]);
                    Path propsPath = Path.of(args[4]);
                    store.benchmarking(idsPath, labelsPath, propsPath);
                }

                case "-g" -> { 
                    if (args.length < 3) usage();
                    String nodeId = args[2];
                    System.out.println("Querying Node ID: " + nodeId);
                    long start = System.nanoTime();
                    NodeBlob n = store.getNode(nodeId);
                    long end = System.nanoTime();
                    if (n == null) {
                        System.out.println("Node not found");
                    } else {
                        System.out.println("label=" + n.label);
                        System.out.println("props=" + n.props);
                    }
                    System.out.printf(Locale.ROOT, "Query time: %.3f ms%n", (end - start) / 1e6);
                }

                case "-gel" -> { 
                    if (args.length < 3) usage();
                    String label = args[2];
                    System.out.println("Querying edges with Label: " + label);
                    long start = System.nanoTime();
                    AtomicLong c = new AtomicLong();
                    store.forEachEdgeIdByLabel(label, eid -> {
                        long idx = c.incrementAndGet();
                        if (idx <= 10) System.out.println("  Found Edge ID: " + eid);
                    });
                    long end = System.nanoTime();
                    if (c.get() > 10) System.out.println("  ... (total " + c.get() + ")");
                    System.out.printf(Locale.ROOT, "Total edges: %,d. Query time: %.3f ms%n", c.get(), (end - start) / 1e6);
                }

                case "-nv" -> { 
                    if (args.length < 3 || !args[2].contains("=")) usage();
                    String[] kv = args[2].split("=", 2);
                    String key = kv[0];
                    String val = kv[1];
                    System.out.println("Querying nodes where " + key + " = " + val);
                    long start = System.nanoTime();
                    AtomicLong c = new AtomicLong();
                    store.forEachNodeByPropertyEquals(key, val, nid -> {
                        long idx = c.incrementAndGet();
                        if (idx <= 10) System.out.println("  Found Node ID: " + nid);
                    });
                    long end = System.nanoTime();
                    if (c.get() > 10) System.out.println("  ... (total " + c.get() + ")");
                    System.out.printf(Locale.ROOT, "Total nodes: %,d. Query time: %.3f ms%n", c.get(), (end - start) / 1e6);
                }
                default -> usage();
            }
        }
    }

    private static void usage() {
        System.err.println("""
          Usage:
            Config mode:
              java ... ingest <benchmark.properties>
              java ... bench <benchmark.properties>

            Direct Ingest:
              java ... ingest <nodes.pgdf> <edges.pgdf> <db_path>

            Direct Benchmark:
              java ... <db_path> bench <ids_file> <labels_file> <props_file>

            Queries:
              java ... <db_path> -g  <nodeId>
              java ... <db_path> -gel <label>
              java ... <db_path> -nv <key=value>
        """);
        System.exit(2);
    }

    public static Properties loadConfig(String path) throws IOException {
        Properties props = new Properties();
        try (java.io.InputStream in = Files.newInputStream(Path.of(path))) {
            props.load(in);
        }
        return props;
    }

    public static Path resolvePath(Path baseDir, String pathStr) {
        if (pathStr == null || pathStr.isBlank()) return null;
        Path p = Path.of(pathStr);
        return p.isAbsolute() ? p : baseDir.resolve(p).normalize();
    }

    public void benchmarking(Path idsPath, Path labelsPath, Path propsPath) throws IOException {
        List<String> ids = Files.readAllLines(idsPath);
        List<String> labels = Files.readAllLines(labelsPath);
        List<String> props = Files.readAllLines(propsPath);

        System.out.println("Benchmark ...");

        long totalGetNode = 0;
        System.out.println("\ngetNode");
        for (String id : ids) {
            long t0 = System.nanoTime();
            getNode(id);
            long t1 = System.nanoTime();
            long diff = t1 - t0;
            totalGetNode += diff;
            System.out.printf(Locale.ROOT, "ID %s: %.4f ms%n", id, diff / 1e6);
        }

        long totalLabels = 0;
        System.out.println("\nforEachEdgeIdByLabel");
        for (String label : labels) {
            AtomicLong count = new AtomicLong();
            long t0 = System.nanoTime();
            forEachEdgeIdByLabel(label, eid -> count.incrementAndGet());
            long t1 = System.nanoTime();
            long diff = t1 - t0;
            totalLabels += diff;
            System.out.printf(Locale.ROOT, "Label %s (found %d): %.4f ms%n", label, count.get(), diff / 1e6);
        }

        long totalProps = 0;
        System.out.println("\nforEachNodeByPropertyEquals");
        for (String line : props) {
            String[] kv = line.split("=", 2);
            if (kv.length < 2) continue;
            String k = kv[0];
            String v = kv[1];
            AtomicLong count = new AtomicLong();
            long t0 = System.nanoTime();
            forEachNodeByPropertyEquals(k, v, nid -> count.incrementAndGet());
            long t1 = System.nanoTime();
            long diff = t1 - t0;
            totalProps += diff;
            System.out.printf(Locale.ROOT, "Prop %s=%s (found %d): %.4f ms%n", k, v, count.get(), diff / 1e6);
        }

        System.out.println("\n==========================================");
        System.out.println("BENCHMARK (MapDB)");
        System.out.println("==========================================");
        printStats("getNode", ids.size(), totalGetNode);
        printStats("forEachEdgeIdByLabel", labels.size(), totalLabels);
        printStats("forEachNodeByPropertyEquals", props.size(), totalProps);
    }

    private void printStats(String op, int count, long totalNs) {
        double totalMs = totalNs / 1e6;
        double avgMs = totalMs / count;
        System.out.printf(Locale.ROOT, "%-28s | Total: %8.3f ms | Avg: %8.4f ms | Count: %d%n", op, totalMs, avgMs, count);
    }

    public void runBenchmarkConfig(Properties cfg, Path baseDir, String overrideCond, Integer overrideRep) throws IOException {
        Path idsPath = resolvePath(baseDir, cfg.getProperty("ids_path"));
        Path labelsPath = resolvePath(baseDir, cfg.getProperty("labels_path"));
        Path propsPath = resolvePath(baseDir, cfg.getProperty("props_path"));

        String sf = cfg.getProperty("scale_factor", "sf1");
        Path resultsDir = resolvePath(baseDir, cfg.getProperty("results_dir", "results"));
        String targetCond = overrideCond != null ? overrideCond : cfg.getProperty("benchmark_condition", "warm");
        int warmup = Integer.parseInt(cfg.getProperty("warmup_iterations", "3"));
        int measured = Integer.parseInt(cfg.getProperty("measured_iterations", "5"));
        long seed = Long.parseLong(cfg.getProperty("random_seed", "42"));
        boolean shuffle = Boolean.parseBoolean(System.getProperty("shuffle_queries", cfg.getProperty("shuffle_queries", "true")));

        List<String> ids = Files.readAllLines(idsPath);
        List<String> labels = Files.readAllLines(labelsPath);
        List<String> props = Files.readAllLines(propsPath);

        Files.createDirectories(resultsDir);
        Path csvPath = resultsDir.resolve("benchmark_mapdb.csv");

        if ("cold".equalsIgnoreCase(targetCond)) {
            int rep = overrideRep != null ? overrideRep : 1;
            boolean writeHeader = !Files.exists(csvPath);
            try (PrintWriter pw = new PrintWriter(Files.newBufferedWriter(csvPath, StandardCharsets.UTF_8,
                    StandardOpenOption.CREATE, StandardOpenOption.APPEND))) {
                if (writeHeader) {
                    pw.println("engine,scale_factor,condition,repetition,query_type,param,time_ms,cardinality");
                }
                executeBenchmarkPass(ids, labels, props, "cold", rep, seed + rep, sf, pw, shuffle);
            }
        } else {
            // Warm or Both: run warmup iterations (discarded), then measured iterations
            System.out.printf(Locale.ROOT, "Executing %d warm-up passes (discarded)...%n", warmup);
            for (int w = 1; w <= warmup; w++) {
                executeBenchmarkPass(ids, labels, props, "warmup", w, seed - w, sf, null, shuffle);
            }
            System.out.printf(Locale.ROOT, "Executing %d measured warm passes...%n", measured);
            boolean writeHeader = !Files.exists(csvPath);
            try (PrintWriter pw = new PrintWriter(Files.newBufferedWriter(csvPath, StandardCharsets.UTF_8,
                    StandardOpenOption.CREATE, StandardOpenOption.APPEND))) {
                if (writeHeader) {
                    pw.println("engine,scale_factor,condition,repetition,query_type,param,time_ms,cardinality");
                }
                for (int rep = 1; rep <= measured; rep++) {
                    executeBenchmarkPass(ids, labels, props, "warm", rep, seed + rep, sf, pw, shuffle);
                }
            }
        }
    }

    private void executeBenchmarkPass(List<String> idsOrig, List<String> labelsOrig, List<String> propsOrig,
            String condition, int repetition, long seed, String sf, PrintWriter pw, boolean shuffle) {
        List<String> ids = new ArrayList<>(idsOrig);
        List<String> labels = new ArrayList<>(labelsOrig);
        List<String> props = new ArrayList<>(propsOrig);

        if (shuffle && seed >= 0) {
            Random rnd = new Random(seed);
            Collections.shuffle(ids, rnd);
            Collections.shuffle(labels, rnd);
            Collections.shuffle(props, rnd);
        }

        long totalQ1 = 0;
        for (String id : ids) {
            long t0 = System.nanoTime();
            NodeBlob n = getNode(id);
            long t1 = System.nanoTime();
            long diff = t1 - t0;
            totalQ1 += diff;
            long card = (n != null) ? 1 : 0;
            if (pw != null) {
                pw.printf(Locale.ROOT, "mapdb,%s,%s,%d,Q1,%s,%.4f,%d%n",
                        sf, condition, repetition, id, diff / 1e6, card);
            }
        }

        long totalQ2 = 0;
        for (String label : labels) {
            AtomicLong count = new AtomicLong();
            long t0 = System.nanoTime();
            forEachEdgeIdByLabel(label, eid -> count.incrementAndGet());
            long t1 = System.nanoTime();
            long diff = t1 - t0;
            totalQ2 += diff;
            long card = count.get();
            if (pw != null) {
                pw.printf(Locale.ROOT, "mapdb,%s,%s,%d,Q2,%s,%.4f,%d%n",
                        sf, condition, repetition, label, diff / 1e6, card);
            }
        }

        long totalQ3 = 0;
        for (String line : props) {
            String[] kv = line.split("=", 2);
            if (kv.length < 2) continue;
            String k = kv[0];
            String v = kv[1];
            AtomicLong count = new AtomicLong();
            long t0 = System.nanoTime();
            forEachNodeByPropertyEquals(k, v, nid -> count.incrementAndGet());
            long t1 = System.nanoTime();
            long diff = t1 - t0;
            totalQ3 += diff;
            long card = count.get();
            if (pw != null) {
                pw.printf(Locale.ROOT, "mapdb,%s,%s,%d,Q3,%s,%.4f,%d%n",
                        sf, condition, repetition, line, diff / 1e6, card);
            }
        }
        if (pw != null) {
            pw.flush();
            System.out.printf(Locale.ROOT, "  [Rep %d (%s)] Q1: %.2f ms | Q2: %.2f ms | Q3: %.2f ms%n",
                    repetition, condition, totalQ1 / 1e6, totalQ2 / 1e6, totalQ3 / 1e6);
        }
    }

    private Main(DB db,
                 HTreeMap<String, NodeBlob> nodes,
                 HTreeMap<String, EdgeBlob> edges,
                 NavigableSet<KeyTuple> idxEdgeIdsByLabel,
                 NavigableSet<KeyTuple> idxNodesByProp) {
        this.db = db;
        this.nodes = nodes;
        this.edges = edges;
        this.idxEdgeIdsByLabel = idxEdgeIdsByLabel;
        this.idxNodesByProp = idxNodesByProp;
    }

    @SuppressWarnings("unchecked")
    public static Main open(Path folder) {
        folder.toFile().mkdirs();
        File dbFile = folder.resolve(DB_FILE_NAME).toFile();

        DB db = DBMaker.fileDB(dbFile)
                .fileMmapEnableIfSupported()
                .closeOnJvmShutdown()
                .concurrencyScale(16)
                .make();

        HTreeMap<String, NodeBlob> nodes = db.hashMap(MAP_NODES, Serializer.STRING, Serializer.JAVA).createOrOpen();
        HTreeMap<String, EdgeBlob> edges = db.hashMap(MAP_EDGES, Serializer.STRING, Serializer.JAVA).createOrOpen();

        NavigableSet<KeyTuple> idxEdgeIdsByLabel = (NavigableSet<KeyTuple>) db.treeSet(IDX_EDGEIDS_BY_LABEL, Serializer.JAVA).createOrOpen();
        NavigableSet<KeyTuple> idxNodesByProp    = (NavigableSet<KeyTuple>) db.treeSet(IDX_NODES_BY_PROP,    Serializer.JAVA).createOrOpen();

        return new Main(db, nodes, edges, idxEdgeIdsByLabel, idxNodesByProp);
    }

    @Override
    public void close() {
        if (db != null && !db.isClosed()) {
            db.commit();
            db.close();
        }
    }

    public static final class NodeBlob implements Serializable {
        @Serial private static final long serialVersionUID = 1L;
        public final String label;
        public final Map<String, String> props;
        public NodeBlob(String label, Map<String, String> props) {
            this.label = label;
            this.props = new LinkedHashMap<>(props);
        }
        @Override public String toString() { return "Node{label="+label+", props="+props+"}"; }
    }

    public static final class EdgeBlob implements Serializable {
        @Serial private static final long serialVersionUID = 1L;
        public final String label;
        public final String src;
        public final String dst;
        public EdgeBlob(String label, String src, String dst) {
            this.label = label; this.src = src; this.dst = dst;
        }
        @Override public String toString() { return "Edge{label="+label+", src="+src+", dst="+dst+"}"; }
    }

    public static final class KeyTuple implements Serializable, Comparable<KeyTuple> {
        @Serial private static final long serialVersionUID = 1L;
        
        final int type;
        final String p1;
        final String p2;
        final String p3;

        public KeyTuple(String label, String edgeId) {
            this.type = 1;
            this.p1 = label;
            this.p2 = edgeId;
            this.p3 = "";
        }

        public KeyTuple(String key, String val, String nodeId) {
            this.type = 2;
            this.p1 = key;
            this.p2 = val;
            this.p3 = nodeId;
        }

        @Override
        public int compareTo(KeyTuple o) {
            if (this.type != o.type) return Integer.compare(this.type, o.type);
            int cmp = this.p1.compareTo(o.p1);
            if (cmp != 0) return cmp;
            cmp = this.p2.compareTo(o.p2);
            if (cmp != 0) return cmp;
            return this.p3.compareTo(o.p3);
        }
    }

    public void runIngest(Path nodes, Path edges) throws IOException {
        runIngest(nodes, edges, null, null);
    }

    public void runIngest(Path nodes, Path edges, String scaleFactor, Path resultsDir) throws IOException {
        System.out.println("Starting Ingest...");
        long t0 = System.nanoTime();
        long nodesCount = ingestNodes(nodes);
        long edgesCount = ingestEdges(edges);
        long t1 = System.nanoTime();

        db.commit();
        long t2 = System.nanoTime();

        double tInsertMs = (t1 - t0) / 1e6;
        double tIndexMs = (t2 - t1) / 1e6;
        double tTotalMs = (t2 - t0) / 1e6;

        printIngestSummary("MapDB", scaleFactor, nodesCount, edgesCount, tInsertMs, tIndexMs, tTotalMs);

        if (resultsDir != null) {
            recordIngestMetrics(resultsDir, "mapdb", scaleFactor == null ? "N/A" : scaleFactor,
                    nodesCount, edgesCount, tInsertMs, tIndexMs, tTotalMs);
        }
    }

    public long ingestNodes(Path nodesPgdf) throws IOException {
        try (BufferedReader br = Files.newBufferedReader(nodesPgdf, StandardCharsets.UTF_8)) {
            String line; String[] header = null;
            long written = 0;
            long nCount = 0;

            while ((line = br.readLine()) != null) {
                if (line.isBlank()) continue;
                if (line.startsWith("@")) {
                    header = Arrays.stream(line.split("\\|")).map(String::trim).toArray(String[]::new);
                    continue;
                }
                if (header == null) continue;

                String[] cols = line.split("\\|", -1);
                Map<String,String> row = new LinkedHashMap<>();
                for (int i=0;i<header.length && i<cols.length;i++) row.put(header[i], cols[i]);

                String nodeId = row.getOrDefault("@id","").trim();
                String label  = row.getOrDefault("@label","").trim();
                if (nodeId.isEmpty() || label.isEmpty()) continue;

                Map<String,String> props = new LinkedHashMap<>();
                for (var e : row.entrySet()){
                    String k = e.getKey();
                    if ("@id".equals(k) || "@label".equals(k)) continue;
                    String v = e.getValue() == null ? "" : e.getValue();
                    if (!v.isEmpty()) props.put(k, v);
                }

                nodes.put(nodeId, new NodeBlob(label, props));

                for (var e : props.entrySet()) {
                    String val = e.getValue();
                    if (val == null || val.isEmpty()) continue;
                    idxNodesByProp.add(new KeyTuple(e.getKey(), val, nodeId));
                }

                nCount++;
                if ((++written % NODE_BATCH) == 0) db.commit();
            }
            db.commit();
            System.out.printf(Locale.ROOT, "  Nodes loaded: %,d%n", nCount);
            return nCount;
        }
    }

    public long ingestEdges(Path edgesPgdf) throws IOException {
        try (BufferedReader br = Files.newBufferedReader(edgesPgdf, StandardCharsets.UTF_8)) {
            String line = br.readLine();
            if (line == null) return 0;
            
            String[] headerLine = line.split("\\|", -1);
            Map<String,Integer> idx = new HashMap<>();
            for(int i=0; i<headerLine.length; i++) idx.put(headerLine[i], i);

            long written = 0;
            long eCount = 0;

            while ((line = br.readLine()) != null) {
                if (line.isBlank() || line.startsWith("@")) continue;

                String[] cols = line.split("\\|", -1);
                
                String label = safeGet(cols, idx.get("@label"));
                String src   = safeGet(cols, idx.get("@out"));
                String dst   = safeGet(cols, idx.get("@in"));
                String dir   = safeGet(cols, idx.get("@dir"));
                
                if (label.isEmpty() || src.isEmpty() || dst.isEmpty()) continue;
                if (dir != null && !"T".equalsIgnoreCase(dir) && !dir.isEmpty()) continue; 

                String edgeId = safeGet(cols, idx.get("@id"));
                if (edgeId.isEmpty()) edgeId = makeEdgeId(src, label, dst);

                edges.put(edgeId, new EdgeBlob(label, src, dst));

                idxEdgeIdsByLabel.add(new KeyTuple(label, edgeId));

                eCount++;
                if ((++written % EDGE_BATCH) == 0) db.commit();
            }
            db.commit();
            System.out.printf(Locale.ROOT, "  Edges loaded: %,d%n", eCount);
            return eCount;
        }
    }

    public NodeBlob getNode(String nodeId) {
        return nodes.get(nodeId);
    }

    public void forEachEdgeIdByLabel(String label, Consumer<String> edgeIdConsumer) {
        KeyTuple min = new KeyTuple(label, "");
        KeyTuple max = new KeyTuple(label, HI_SENTINEL);

        for (KeyTuple t : idxEdgeIdsByLabel.subSet(min, true, max, true)) {
            edgeIdConsumer.accept(t.p2); 
        }
    }

    public void forEachNodeByPropertyEquals(String propName, String propValue, Consumer<String> nodeIdConsumer) {
        KeyTuple min = new KeyTuple(propName, propValue, "");
        KeyTuple max = new KeyTuple(propName, propValue, HI_SENTINEL);

        for (KeyTuple t : idxNodesByProp.subSet(min, true, max, true)) {
            nodeIdConsumer.accept(t.p3); 
        }
    }

    private static String makeEdgeId(String src, String label, String dst) {
        String s = src + "|" + label + "|" + dst;
        long x = 1125899906842597L;
        for (int i=0;i<s.length();i++) x = (x * 1315423911L) ^ s.charAt(i);
        return Long.toUnsignedString(x);
    }
    
    private static String safeGet(String[] arr, Integer i) {
        if (i == null || i < 0 || i >= arr.length) return "";
        String s = arr[i];
        return s == null ? "" : s.trim();
    }

    public static void printIngestSummary(String engine, String sf, long nodesCount, long edgesCount,
            double tInsertMs, double tIndexMs, double tTotalMs) {
        System.out.println("\n==========================================");
        System.out.printf(Locale.ROOT, "INGEST METRICS (%s)%n", engine);
        System.out.println("==========================================");
        if (sf != null && !sf.isBlank()) {
            System.out.printf(Locale.ROOT, "Scale Factor : %s%n", sf);
        }
        System.out.printf(Locale.ROOT, "Nodes Loaded : %,d%n", nodesCount);
        System.out.printf(Locale.ROOT, "Edges Loaded : %,d%n", edgesCount);
        System.out.printf(Locale.ROOT, "Insert Time  : %10.3f ms%n", tInsertMs);
        System.out.printf(Locale.ROOT, "Index Time   : %10.3f ms%n", tIndexMs);
        System.out.printf(Locale.ROOT, "Total Time   : %10.3f ms%n", tTotalMs);
        System.out.println("==========================================");
    }

    public static synchronized void recordIngestMetrics(Path resultsDir, String engine, String sf,
            long nodesCount, long edgesCount, double tInsertMs, double tIndexMs, double tTotalMs) {
        if (resultsDir == null) return;
        try {
            Files.createDirectories(resultsDir);
            Path csvPath = resultsDir.resolve("ingest_mapdb.csv");
            try (PrintWriter pw = new PrintWriter(Files.newBufferedWriter(csvPath, StandardCharsets.UTF_8,
                    StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING, StandardOpenOption.WRITE))) {
                pw.println("engine,scale_factor,nodes_count,edges_count,t_insert_ms,t_index_ms,t_total_ms");
                pw.printf(Locale.ROOT, "%s,%s,%d,%d,%.3f,%.3f,%.3f%n",
                        engine.toLowerCase(Locale.ROOT), sf, nodesCount, edgesCount, tInsertMs, tIndexMs, tTotalMs);
            }
        } catch (IOException e) {
            System.err.println("[WARN] Could not write ingest metrics to CSV: " + e.getMessage());
        }
    }
}