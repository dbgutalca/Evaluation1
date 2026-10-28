import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.sql.*;
import java.util.*;

public class PostgresColumns {

    private static final int NODE_BATCH = 50_000;
    private static final int EDGE_BATCH = 100_000;
    private static final int PROP_BATCH = 100_000;

    public static void main(String[] args) throws Exception {
        if (args.length == 2 && ("ingest".equals(args[0]) || "bench".equals(args[0]))) {
            Path configPath = Paths.get(args[1]).toAbsolutePath();
            Path baseDir = configPath.getParent();
            Properties cfg = loadConfig(configPath.toString());
            String url = cfg.getProperty("postgres_url", "jdbc:postgresql://localhost:5432/postgres");
            String user = cfg.getProperty("postgres_user", "postgres");
            String pass = cfg.getProperty("postgres_pass", "postgres");
            try (Connection cx = DriverManager.getConnection(url, user, pass)) {
                cx.setAutoCommit(false);
                if ("ingest".equals(args[0])) {
                    Path nodesFile = resolvePath(baseDir, cfg.getProperty("nodes_path"));
                    Path edgesFile = resolvePath(baseDir, cfg.getProperty("edges_path"));
                    runIngest(cx, nodesFile, edgesFile);
                } else {
                    Path idsPath = resolvePath(baseDir, cfg.getProperty("ids_path"));
                    Path labelsPath = resolvePath(baseDir, cfg.getProperty("labels_path"));
                    Path propsPath = resolvePath(baseDir, cfg.getProperty("props_path"));
                    benchmarking(cx, idsPath, labelsPath, propsPath);
                }
                cx.commit();
            }
            return;
        }

        if (args.length < 4) {
            usage();
        }

        String url  = args[0];
        String user = args[1];
        String pass = args[2];
        String flag = args[3];

        try (Connection cx = DriverManager.getConnection(url, user, pass)) {
            cx.setAutoCommit(false);

            if (!flag.startsWith("-") && !flag.equals("bench")) {
                if (args.length < 5) usage();
                Path nodesFile = Paths.get(args[3]);
                Path edgesFile = Paths.get(args[4]);
                
                runIngest(cx, nodesFile, edgesFile);
                return;
            }

            switch (flag) {
                case "bench" -> {
                    if (args.length < 7) usage();
                    Path idsPath = Paths.get(args[4]);
                    Path labelsPath = Paths.get(args[5]);
                    Path propsPath = Paths.get(args[6]);
                    benchmarking(cx, idsPath, labelsPath, propsPath);
                }
                case "-g" -> { 
                    if (args.length < 5) usage();
                    String nodeId = args[4];
                    queryNodeWithAllProps(cx, nodeId);
                }
                case "-gel" -> {
                    if (args.length < 5) usage();
                    String label = args[4];
                    queryEdgeIdsByLabel(cx, label);
                }
                case "-nv" -> { 
                    if (args.length < 5) usage();
                    String spec = args[4]; 
                    String[] parts = spec.split("=");
                    if (parts.length != 2) {
                        System.err.println("Invalid format");
                        System.exit(2);
                    }
                    queryNodesByPropEquals(cx, parts[0], parts[1]);
                }
                default -> usage();
            }
            
            cx.commit();
        }
    }

    private static void usage() {
        System.err.println("""
            Usage:
              Config mode:
                java ... ingest <benchmark.properties>
                java ... bench <benchmark.properties>

              Direct Ingest:
                java ... <jdbc_url> <user> <pass> <Nodes.pgdf> <Edges.pgdf>
              
              Direct Benchmark:
                java ... <jdbc_url> <user> <pass> bench <ids_file> <labels_file> <props_file>

              Queries:
                java ... <jdbc_url> <user> <pass> -g <node_id>
                java ... <jdbc_url> <user> <pass> -gel <label>
                java ... <jdbc_url> <user> <pass> -nv <key=value>
            """);
        System.exit(2);
    }

    public static Properties loadConfig(String path) throws IOException {
        Properties props = new Properties();
        try (java.io.InputStream in = Files.newInputStream(Paths.get(path))) {
            props.load(in);
        }
        return props;
    }

    public static Path resolvePath(Path baseDir, String pathStr) {
        if (pathStr == null || pathStr.isBlank()) return null;
        Path p = Paths.get(pathStr);
        return p.isAbsolute() ? p : baseDir.resolve(p).normalize();
    }

    public static final String SQL_GET_NODE = "SELECT label, key, value FROM node_properties WHERE node_id = ?";
    public static final String SQL_EDGES_BY_LABEL = "SELECT id FROM edges WHERE label = ?";
    public static final String SQL_NODES_BY_PROP = "SELECT node_id FROM node_properties WHERE key = ? AND value = ?";

    public static final class NodeData {
        public final String label;
        public final Map<String, String> props;

        public NodeData(String label, Map<String, String> props) {
            this.label = label;
            this.props = props;
        }

        @Override
        public String toString() {
            return "NodeData{label=" + label + ", props=" + props + "}";
        }
    }

    public static NodeData getNode(PreparedStatement ps, String nodeId) throws SQLException {
        ps.setString(1, nodeId);
        String label = null;
        Map<String, String> props = null;
        try (ResultSet rs = ps.executeQuery()) {
            while (rs.next()) {
                if (label == null) {
                    label = rs.getString(1);
                    props = new LinkedHashMap<>();
                }
                props.put(rs.getString(2), rs.getString(3));
            }
        }
        return label == null ? null : new NodeData(label, props);
    }

    public static NodeData getNode(Connection cx, String nodeId) throws SQLException {
        try (PreparedStatement ps = cx.prepareStatement(SQL_GET_NODE)) {
            return getNode(ps, nodeId);
        }
    }

    public static long forEachEdgeIdByLabel(PreparedStatement ps, String label, java.util.function.Consumer<String> consumer) throws SQLException {
        ps.setString(1, label);
        long count = 0;
        try (ResultSet rs = ps.executeQuery()) {
            while (rs.next()) {
                String eid = rs.getString(1);
                if (consumer != null) {
                    consumer.accept(eid);
                }
                count++;
            }
        }
        return count;
    }

    public static long forEachEdgeIdByLabel(Connection cx, String label, java.util.function.Consumer<String> consumer) throws SQLException {
        try (PreparedStatement ps = cx.prepareStatement(SQL_EDGES_BY_LABEL)) {
            return forEachEdgeIdByLabel(ps, label, consumer);
        }
    }

    public static long forEachNodeByPropertyEquals(PreparedStatement ps, String key, String value, java.util.function.Consumer<String> consumer) throws SQLException {
        ps.setString(1, key);
        ps.setString(2, value);
        long count = 0;
        try (ResultSet rs = ps.executeQuery()) {
            while (rs.next()) {
                String nid = rs.getString(1);
                if (consumer != null) {
                    consumer.accept(nid);
                }
                count++;
            }
        }
        return count;
    }

    public static long forEachNodeByPropertyEquals(Connection cx, String key, String value, java.util.function.Consumer<String> consumer) throws SQLException {
        try (PreparedStatement ps = cx.prepareStatement(SQL_NODES_BY_PROP)) {
            return forEachNodeByPropertyEquals(ps, key, value, consumer);
        }
    }

    public static void benchmarking(Connection cx, Path idsPath, Path labelsPath, Path propsPath) throws Exception {
        List<String> ids = Files.readAllLines(idsPath);
        List<String> labels = Files.readAllLines(labelsPath);
        List<String> props = Files.readAllLines(propsPath);

        System.out.println("Benchmark...");

        long totalGetNode = 0;
        System.out.println("\ngetNode");
        try (PreparedStatement ps = cx.prepareStatement(SQL_GET_NODE)) {
            for (String id : ids) {
                long t0 = System.nanoTime();
                getNode(ps, id);
                long t1 = System.nanoTime();
                long diff = t1 - t0;
                totalGetNode += diff;
                System.out.printf(Locale.ROOT, "ID %s: %.4f ms%n", id, diff / 1e6);
            }
        }

        long totalLabels = 0;
        System.out.println("\nqueryEdgeIdsByLabel");
        try (PreparedStatement ps = cx.prepareStatement(SQL_EDGES_BY_LABEL)) {
            for (String label : labels) {
                long t0 = System.nanoTime();
                long count = forEachEdgeIdByLabel(ps, label, null);
                long t1 = System.nanoTime();
                long diff = t1 - t0;
                totalLabels += diff;
                System.out.printf(Locale.ROOT, "Label %s (found %d): %.4f ms%n", label, count, diff / 1e6);
            }
        }

        long totalProps = 0;
        System.out.println("\nqueryNodesByPropEquals");
        try (PreparedStatement ps = cx.prepareStatement(SQL_NODES_BY_PROP)) {
            for (String line : props) {
                String[] kv = line.split("=", 2);
                if (kv.length < 2) continue;
                String k = kv[0];
                String v = kv[1];
                long t0 = System.nanoTime();
                long count = forEachNodeByPropertyEquals(ps, k, v, null);
                long t1 = System.nanoTime();
                long diff = t1 - t0;
                totalProps += diff;
                System.out.printf(Locale.ROOT, "Prop %s=%s (found %d): %.4f ms%n", k, v, count, diff / 1e6);
            }
        }

        System.out.println("\n==========================================");
        System.out.println("BENCHMARK (PostgreSQL)");
        System.out.println("==========================================");
        printStats("getNode", ids.size(), totalGetNode);
        printStats("queryEdgeIdsByLabel", labels.size(), totalLabels);
        printStats("queryNodesByPropEquals", props.size(), totalProps);
    }

    private static void printStats(String op, int count, long totalNs) {
        double totalMs = totalNs / 1e6;
        double avgMs = totalMs / count;
        System.out.printf(Locale.ROOT, "%-28s | Total: %8.3f ms | Avg: %8.4f ms | Count: %d%n", op, totalMs, avgMs, count);
    }

    public static void runIngest(Connection cx, Path nodesFile, Path edgesFile) throws Exception {
        System.out.println("Ingesting...");
        long t0 = System.nanoTime();
        ensureTables(cx);
        ingestNodes(cx, nodesFile);
        ingestEdges(cx, edgesFile);
        cx.commit(); 
        createIndexes(cx);
        long t1 = System.nanoTime();
        System.out.printf(Locale.ROOT, "Completed: %.3f ms%n", (t1 - t0)/1e6);
    }

    public static void ensureTables(Connection cx) throws SQLException {
        String ddl =
            "CREATE TABLE IF NOT EXISTS nodes (" +
            "  id    TEXT PRIMARY KEY," +
            "  label TEXT NOT NULL" +
            ");" +
            "CREATE TABLE IF NOT EXISTS node_properties (" +
            "  node_id  TEXT NOT NULL REFERENCES nodes(id)," +
            "  label    TEXT NOT NULL," +
            "  key      TEXT NOT NULL," +
            "  value    TEXT NOT NULL" +
            ");" +
            "CREATE TABLE IF NOT EXISTS edges (" +
            "  id       TEXT PRIMARY KEY," +
            "  label    TEXT NOT NULL," +
            "  src      TEXT NOT NULL REFERENCES nodes(id)," +
            "  dst      TEXT NOT NULL REFERENCES nodes(id)," +
            "  directed BOOLEAN NOT NULL" +
            ");" +
            "CREATE TABLE IF NOT EXISTS edge_properties (" +
            "  edge_id  TEXT NOT NULL REFERENCES edges(id)," +
            "  key      TEXT NOT NULL," +
            "  value    TEXT NOT NULL" +
            ");";
        try (Statement st = cx.createStatement()) {
            st.execute(ddl);
        }
        cx.commit();
    }

    public static void createIndexes(Connection cx) throws SQLException {
        String ddl =
            "CREATE INDEX IF NOT EXISTS idx_nodes_label           ON nodes(label);" +
            "CREATE INDEX IF NOT EXISTS idx_nodeprops_key_val     ON node_properties(key, value);" +
            "CREATE INDEX IF NOT EXISTS idx_edges_label           ON edges(label);" +
            "CREATE INDEX IF NOT EXISTS idx_edges_label_src       ON edges(label, src);" +
            "CREATE INDEX IF NOT EXISTS idx_edges_label_dst       ON edges(label, dst);" +
            "CREATE INDEX IF NOT EXISTS idx_nodeprops_node        ON node_properties(node_id);"; 
        try (Statement st = cx.createStatement()) {
            st.execute(ddl);
        }
        cx.commit();
    }

    public static void ingestNodes(Connection cx, Path nodesPgdf) throws IOException, SQLException {
        final String upsertNode = "INSERT INTO nodes(id,label) VALUES(?,?) ON CONFLICT (id) DO NOTHING"; 
        final String insertProp = "INSERT INTO node_properties(node_id,label,key,value) VALUES(?,?,?,?)";

        try (BufferedReader br = Files.newBufferedReader(nodesPgdf, StandardCharsets.UTF_8);
             PreparedStatement psNode = cx.prepareStatement(upsertNode);
             PreparedStatement psProp = cx.prepareStatement(insertProp)) {

            String line;
            String[] header = null;
            int nBatch = 0, pBatch = 0;
            long nCount = 0;

            while ((line = br.readLine()) != null) {
                if (line.isBlank()) continue;
                if (line.startsWith("@")) {
                    header = line.split("\\|", -1);
                    continue;
                }
                if (header == null) continue;

                String[] cols = line.split("\\|", -1);
                Map<String,String> row = new LinkedHashMap<>();
                for (int i = 0; i < header.length && i < cols.length; i++) {
                    row.put(header[i], cols[i]);
                }

                String id    = nonNull(row.get("@id")).trim();
                String label = nonNull(row.get("@label")).trim();
                if (id.isEmpty() || label.isEmpty()) continue;

                psNode.setString(1, id);
                psNode.setString(2, label);
                psNode.addBatch();
                nBatch++; nCount++;

                for (var e : row.entrySet()) {
                    String k = e.getKey();
                    if (k.startsWith("@")) continue;

                    String v = nonNull(e.getValue());
                    if (v.isEmpty()) continue;

                    psProp.setString(1, id);
                    psProp.setString(2, label);
                    psProp.setString(3, k);
                    psProp.setString(4, v);
                    psProp.addBatch();
                    pBatch++;
                }

                if (nBatch >= NODE_BATCH) {
                    psNode.executeBatch(); 
                    psProp.executeBatch(); 
                    cx.commit();           
                    nBatch = 0;
                    pBatch = 0;
                }
            }

            if (nBatch > 0) psNode.executeBatch();
            if (pBatch > 0) psProp.executeBatch();
            cx.commit();
            
            System.out.printf(Locale.ROOT, "  Nodes processed: %,d%n", nCount);
        }
    } 

    public static void ingestEdges(Connection cx, Path edgesPgdf) throws IOException, SQLException {
        final String insertEdge = "INSERT INTO edges(id,label,src,dst,directed) VALUES(?,?,?,?,?) ON CONFLICT (id) DO NOTHING";

        try (BufferedReader br = Files.newBufferedReader(edgesPgdf, StandardCharsets.UTF_8);
             PreparedStatement psEdge = cx.prepareStatement(insertEdge)) {

            String line = br.readLine();
            if (line == null) return;
            String[] header = line.split("\\|", -1);
            Map<String,Integer> idx = new HashMap<>();
            for (int i=0;i<header.length;i++) idx.put(header[i], i);

            int eBatch = 0;
            long eCount = 0;

            while ((line = br.readLine()) != null) {
                if (line.isBlank() || line.startsWith("@")) continue;
                String[] cols = line.split("\\|", -1);
                String eid  = safe(cols, idx.get("@id"));
                String lab  = safe(cols, idx.get("@label"));
                String dir  = safe(cols, idx.get("@dir"));
                String src  = safe(cols, idx.get("@out"));
                String dst  = safe(cols, idx.get("@in"));

                if (lab.isEmpty() || src.isEmpty() || dst.isEmpty()) continue;
                boolean directed = !"F".equalsIgnoreCase(dir.isEmpty() ? "T" : dir);
                if (eid.isEmpty()) eid = makeEdgeId(src, lab, dst);
           
                psEdge.setString(1, eid);
                psEdge.setString(2, lab);
                psEdge.setString(3, src);
                psEdge.setString(4, dst);
                psEdge.setBoolean(5, directed);
                psEdge.addBatch();
                eBatch++; eCount++;

                if (eBatch >= EDGE_BATCH) {
                    psEdge.executeBatch();
                    eBatch = 0;
                }
            }
            if (eBatch > 0) psEdge.executeBatch();
            System.out.printf(Locale.ROOT, "  Edges processed: %,d%n", eCount);
        }
    }

    public static void queryNodeWithAllProps(Connection cx, String nodeId) throws SQLException {
        System.out.println("Node ID: " + nodeId);
        long t0 = System.nanoTime();
        NodeData n = getNode(cx, nodeId);
        if (n == null) {
            System.out.println("  (not found)");
        } else {
            System.out.println("  Label: " + n.label);
            for (var entry : n.props.entrySet()) {
                System.out.println("  " + entry.getKey() + ": " + entry.getValue());
            }
        }
        long t1 = System.nanoTime();
        System.out.printf(Locale.ROOT, "Time: %.3f ms%n", (t1 - t0)/1e6);
    }

    public static void queryEdgeIdsByLabel(Connection cx, String label) throws SQLException {
        System.out.println("Label: " + label);
        long t0 = System.nanoTime();
        long[] count = new long[1];
        long total = forEachEdgeIdByLabel(cx, label, eid -> {
            count[0]++;
            if (count[0] <= 10) System.out.println("  Edge ID: " + eid);
        });
        long t1 = System.nanoTime();
        if (total > 10) System.out.println("  ... (total " + total + ")");
        System.out.printf(Locale.ROOT, "Edges: %,d. Time: %.3f ms%n", total, (t1 - t0)/1e6);
    }

    public static void queryNodesByPropEquals(Connection cx, String key, String value) throws SQLException {
        System.out.println(key + " = " + value);
        long t0 = System.nanoTime();
        long[] count = new long[1];
        long total = forEachNodeByPropertyEquals(cx, key, value, nid -> {
            count[0]++;
            if (count[0] <= 10) System.out.println("  Node ID: " + nid);
        });
        long t1 = System.nanoTime();
        if (total > 10) System.out.println("  ... (total " + total + ")");
        System.out.printf(Locale.ROOT, "Nodes: %,d. Time: %.3f ms%n", total, (t1 - t0)/1e6);
    }

    private static String nonNull(String s){ return (s == null) ? "" : s; }
    private static String safe(String[] a, Integer i){
        if (i == null || i < 0 || i >= a.length) return "";
        return a[i] == null ? "" : a[i];
    }
    private static String makeEdgeId(String src, String label, String dst) {
        String s = src + "|" + label + "|" + dst;
        long x = 1125899906842597L;
        for (int i=0;i<s.length();i++) x = (x * 1315423911L) ^ s.charAt(i);
        return Long.toUnsignedString(x);
    }
}