package com.neo4j;

import org.neo4j.driver.AuthTokens;
import org.neo4j.driver.Driver;
import org.neo4j.driver.GraphDatabase;
import org.neo4j.driver.Query;
import org.neo4j.driver.Result;
import org.neo4j.driver.Session;
import org.neo4j.driver.Transaction;
import org.neo4j.driver.Record;

import java.io.BufferedReader;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicLong;

import static org.neo4j.driver.Values.parameters;

public class Main {

    private static final int NODE_BATCH = 100;
    private static final int EDGE_BATCH = 100;

    public static void main(String[] args) throws Exception {
        if (args.length == 2 && ("ingest".equals(args[0]) || "bench".equals(args[0]))) {
            Path configPath = Paths.get(args[1]).toAbsolutePath();
            Path baseDir = configPath.getParent();
            Properties cfg = loadConfig(configPath.toString());
            String uri = cfg.getProperty("neo4j_url", "bolt://localhost:7687");
            String user = cfg.getProperty("neo4j_user", "neo4j");
            String pass = cfg.getProperty("neo4j_pass", "password");
            try (Driver driver = GraphDatabase.driver(uri, AuthTokens.basic(user, pass));
                 Session session = driver.session()) {
                if ("ingest".equals(args[0])) {
                    Path nodesFile = resolvePath(baseDir, cfg.getProperty("nodes_path"));
                    Path edgesFile = resolvePath(baseDir, cfg.getProperty("edges_path"));
                    runIngest(session, nodesFile, edgesFile);
                } else {
                    Path idsPath = resolvePath(baseDir, cfg.getProperty("ids_path"));
                    Path labelsPath = resolvePath(baseDir, cfg.getProperty("labels_path"));
                    Path propsPath = resolvePath(baseDir, cfg.getProperty("props_path"));
                    benchmarking(session, idsPath, labelsPath, propsPath);
                }
            }
            return;
        }

        if (args.length < 4) usage();

        String uri  = args[0];
        String user = args[1];
        String pass = args[2];
        String flag = args[3];

        try (Driver driver = GraphDatabase.driver(uri, AuthTokens.basic(user, pass));
             Session session = driver.session()) {

            if (!flag.startsWith("-") && !flag.equals("bench")) {
                if (args.length < 5) usage();
                Path nodesFile = Paths.get(args[3]);
                Path edgesFile = Paths.get(args[4]);

                runIngest(session, nodesFile, edgesFile);
                return;
            }

            switch (flag) {
                case "bench" -> {
                    if (args.length < 7) usage();
                    Path idsPath = Paths.get(args[4]);
                    Path labelsPath = Paths.get(args[5]);
                    Path propsPath = Paths.get(args[6]);
                    benchmarking(session, idsPath, labelsPath, propsPath);
                }
                case "-g" -> {
                    if (args.length < 5) usage();
                    String nodeId = args[4];
                    queryNodeWithAllProps(session, nodeId);
                }
                case "-gel" -> {
                    if (args.length < 5) usage();
                    String label = args[4];
                    queryEdgeIdsByLabel(session, label);
                }
                case "-nv" -> {
                    if (args.length < 5) usage();
                    String spec = args[4]; // key=value
                    int p = spec.indexOf('=');
                    if (p <= 0 || p == spec.length() - 1) {
                        System.err.println("Invalid format for -nv. Use attribute=value");
                        System.exit(2);
                    }
                    String key = spec.substring(0, p);
                    String val = spec.substring(p + 1);
                    queryNodesByPropEquals(session, key, val);
                }
                default -> usage();
            }
        }
    }

    private static void usage() {
        System.err.println("""
            Usage:
              Config mode:
                mvn ... -Dexec.args="ingest <benchmark.properties>"
                mvn ... -Dexec.args="bench <benchmark.properties>"

              Direct Ingest:
                mvn ... -Dexec.args="<uri> <user> <pass> <Nodes.pgdf> <Edges.pgdf>"
              
              Direct Benchmark:
                mvn ... -Dexec.args="<uri> <user> <pass> bench <ids_file> <labels_file> <props_file>"

              Queries:
                java ... -Dexec.args="<uri> <user> <pass> -g <node_id>"
                java ... -Dexec.args="<uri> <user> <pass> -gel <label>"
                java ... -Dexec.args="<uri> <user> <pass> -nv <attr=val>"
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

    public static final String CYPHER_GET_NODE = "MATCH (n:Node) WHERE n.id = $id RETURN n";
    public static final String CYPHER_NODES_BY_PROP = "MATCH (n:Node) WHERE properties(n)[$key] = $val RETURN n.id AS id";

    public static String getCypherNodesByProp(String key) {
        return String.format("MATCH (n:Node) WHERE n.`%s` = $val RETURN n.id AS id", key.replace("`", "``"));
    }

    public static Map<String, Object> getNode(Session session, String id) {
        Result result = session.run(CYPHER_GET_NODE, parameters("id", id));
        if (result.hasNext()) {
            Record rec = result.next();
            return rec.get("n").asNode().asMap();
        }
        return null;
    }

    public static long forEachEdgeIdByLabel(Session session, String label, java.util.function.Consumer<String> consumer) {
        String relType = relType(label);
        String cypherEdges = "MATCH ()-[r:" + relType + "]->() RETURN r.id AS id";
        Result result = session.run(cypherEdges);
        long count = 0;
        while (result.hasNext()) {
            String eid = result.next().get("id").asString();
            if (consumer != null) {
                consumer.accept(eid);
            }
            count++;
        }
        return count;
    }

    public static long forEachNodeByPropertyEquals(Session session, String key, String value, java.util.function.Consumer<String> consumer) {
        String query = getCypherNodesByProp(key);
        Result result = session.run(query, parameters("val", value));
        long count = 0;
        while (result.hasNext()) {
            String nid = result.next().get("id").asString();
            if (consumer != null) {
                consumer.accept(nid);
            }
            count++;
        }
        return count;
    }

    public static void runIngest(Session session, Path nodesFile, Path edgesFile) throws IOException {
        clearDatabase(session);
        ensureSchema(session);
        session.run("CALL db.awaitIndexes()");

        System.out.println("Starting Ingest...");
        long t0 = System.nanoTime();
        
        Set<String> propertyKeys = ingestNodes(session, nodesFile);
        ingestEdges(session, edgesFile);
        createPropertyIndexes(session, propertyKeys);
        
        long t1 = System.nanoTime();
        System.out.printf(Locale.ROOT, "Ingest completed: %.3f ms%n", (t1 - t0) / 1e6);
    }

    public static void benchmarking(Session session, Path idsPath, Path labelsPath, Path propsPath) throws IOException {
        List<String> ids = Files.readAllLines(idsPath);
        List<String> labels = Files.readAllLines(labelsPath);
        List<String> props = Files.readAllLines(propsPath);

        System.out.println("Benchmark...");

        long totalGetNode = 0;
        System.out.println("\ngetNode");
        for (String id : ids) {
            long t0 = System.nanoTime();
            getNode(session, id);
            long t1 = System.nanoTime();
            long diff = t1 - t0;
            totalGetNode += diff;
            System.out.printf(Locale.ROOT, "ID %s: %.4f ms%n", id, diff / 1e6);
        }

        long totalLabels = 0;
        System.out.println("\nqueryEdgeIdsByLabel");
        for (String label : labels) {
            long t0 = System.nanoTime();
            long count = forEachEdgeIdByLabel(session, label, null);
            long t1 = System.nanoTime();
            long diff = t1 - t0;
            totalLabels += diff;
            System.out.printf(Locale.ROOT, "Label %s (found %d): %.4f ms%n", label, count, diff / 1e6);
        }

        long totalProps = 0;
        System.out.println("\nqueryNodesByPropEquals");
        for (String line : props) {
            String[] kv = line.split("=", 2);
            if (kv.length < 2) continue;
            String k = kv[0];
            String v = kv[1];
            
            long t0 = System.nanoTime();
            long count = forEachNodeByPropertyEquals(session, k, v, null);
            long t1 = System.nanoTime();
            long diff = t1 - t0;
            totalProps += diff;
            System.out.printf(Locale.ROOT, "Prop %s=%s (found %d): %.4f ms%n", k, v, count, diff / 1e6);
        }

        System.out.println("\n==========================================");
        System.out.println("BENCHMARK (Neo4j)");
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

    public static void ensureSchema(Session session) {
        session.run("CREATE INDEX node_id IF NOT EXISTS FOR (n:Node) ON (n.id)");
        session.run("CREATE INDEX node_label IF NOT EXISTS FOR (n:Node) ON (n.label)");
    }

    public static Set<String> ingestNodes(Session session, Path nodesPgdf) throws IOException {
        final String cypher = """
            UNWIND $batch AS row
            CREATE (n:Node {id: row.id, label: row.label})
            SET n += row.props
            """;

        Set<String> discoveredProps = new LinkedHashSet<>();

        try (BufferedReader br = Files.newBufferedReader(nodesPgdf, StandardCharsets.UTF_8)) {
            String line;
            String[] header = null;
            long nCount = 0;

            List<Map<String, Object>> batch = new ArrayList<>(NODE_BATCH);

            while ((line = br.readLine()) != null) {
                if (line.isBlank()) continue;

                if (line.startsWith("@")) {
                    header = line.split("\\|", -1);
                    for (String col : header) {
                        String clean = col.trim();
                        if (!clean.isEmpty() && !clean.startsWith("@") && !clean.equalsIgnoreCase("id") && !clean.equalsIgnoreCase("label")) {
                            discoveredProps.add(clean);
                        }
                    }
                    continue;
                }
                if (header == null) continue;

                String[] cols = line.split("\\|", -1);
                Map<String, String> row = new LinkedHashMap<>();
                for (int i = 0; i < header.length && i < cols.length; i++) {
                    row.put(header[i], cols[i]);
                }

                String id = nonNull(row.get("@id")).trim();
                String label = nonNull(row.get("@label")).trim();
                if (id.isEmpty() || label.isEmpty()) continue;

                Map<String, Object> props = new LinkedHashMap<>();
                for (var e : row.entrySet()) {
                    String k = e.getKey();
                    if ("@id".equals(k) || "@label".equals(k)) continue;
                    String v = nonNull(e.getValue()).trim();
                    if (!v.isEmpty()) {
                        props.put(k, v);
                        discoveredProps.add(k);
                    }
                }

                Map<String, Object> nodeData = new HashMap<>();
                nodeData.put("id", id);
                nodeData.put("label", label);
                nodeData.put("props", props);
                batch.add(nodeData);
                nCount++;

                if (batch.size() >= NODE_BATCH) {
                    try (Transaction tx = session.beginTransaction()) {
                        tx.run(new Query(cypher, parameters("batch", batch)));
                        tx.commit();
                    }
                    batch.clear();
                }
            }

            if (!batch.isEmpty()) {
                try (Transaction tx = session.beginTransaction()) {
                    tx.run(new Query(cypher, parameters("batch", batch)));
                    tx.commit();
                }
                batch.clear();
            }

            System.out.printf(Locale.ROOT, "  Nodes loaded: %,d%n", nCount);
        }
        return discoveredProps;
    }

    public static void createPropertyIndexes(Session session, Collection<String> properties) {
        if (properties == null || properties.isEmpty()) return;
        for (String prop : properties) {
            String indexName = "idx_node_prop_" + prop.replaceAll("[^a-zA-Z0-9_]", "_");
            String cql = String.format("CREATE INDEX %s IF NOT EXISTS FOR (n:Node) ON (n.`%s`)",
                    indexName, prop.replace("`", "``"));
            session.run(cql);
        }
        session.run("CALL db.awaitIndexes()");
    }


    public static void ingestEdges(Session session, Path edgesPgdf) throws IOException {
        try (BufferedReader br = Files.newBufferedReader(edgesPgdf, StandardCharsets.UTF_8)) {
            String line = br.readLine();
            if (line == null) {
                System.out.println("  Edges loaded: 0");
                return;
            }

            String[] header = line.split("\\|", -1);
            Map<String, Integer> idx = new HashMap<>();
            for (int i = 0; i < header.length; i++) idx.put(header[i], i);

            long eCount = 0;
            int batchCount = 0;
            List<Map<String, Object>> batch = new ArrayList<>(EDGE_BATCH);

            while ((line = br.readLine()) != null) {
                if (line.isBlank() || line.startsWith("@")) continue;

                String[] cols = line.split("\\|", -1);
                String eid = safe(cols, idx.get("@id"));
                String lab = safe(cols, idx.get("@label"));
                String dir = safe(cols, idx.get("@dir"));
                String src = safe(cols, idx.get("@out"));
                String dst = safe(cols, idx.get("@in"));

                if (lab.isEmpty() || src.isEmpty() || dst.isEmpty()) continue;

                boolean directed = !"F".equalsIgnoreCase(dir.isEmpty() ? "T" : dir);
                if (eid.isEmpty()) eid = makeEdgeId(src, lab, dst);

                batch.add(Map.of(
                    "eid", eid,
                    "label", lab,
                    "src", src,
                    "dst", dst,
                    "directed", directed
                ));

                batchCount++;
                eCount++;

                if (batchCount >= EDGE_BATCH) {
                    try (Transaction tx = session.beginTransaction()) {
                        executeEdgeBatch(tx, batch);
                        tx.commit();
                    }
                    batch.clear();
                    batchCount = 0;
                }
            }

            if (!batch.isEmpty()) {
                try (Transaction tx = session.beginTransaction()) {
                    executeEdgeBatch(tx, batch);
                    tx.commit();
                }
                batch.clear();
            }

            System.out.printf(Locale.ROOT, "  Edges loaded: %,d%n", eCount);
        }
    }

    public static void executeEdgeBatch(Transaction tx, List<Map<String, Object>> batch) {
        Map<String, List<Map<String, Object>>> grouped = new HashMap<>();
        for (Map<String, Object> edge : batch) {
            String label = (String) edge.get("label");
            grouped.computeIfAbsent(label, k -> new ArrayList<>()).add(edge);
        }

        for (Map.Entry<String, List<Map<String, Object>>> entry : grouped.entrySet()) {
            String relType = relType(entry.getKey());

            String cypher = """
                UNWIND $batch AS row
                MATCH (src:Node {id: row.src})
                MATCH (dst:Node {id: row.dst})
                MERGE (src)-[r:%s {id: row.eid}]->(dst)
                SET r.directed = row.directed
                """.formatted(relType);

            tx.run(new Query(cypher, parameters("batch", entry.getValue())));
        }
    }

    // -g <node_id>
    public static void queryNodeWithAllProps(Session session, String nodeId) {
        System.out.println("Querying Node ID: " + nodeId);
        long t0 = System.nanoTime();
        
        Map<String, Object> props = getNode(session, nodeId);

        if (props == null) {
            System.out.println("Node not found: " + nodeId);
            long t1 = System.nanoTime(); 
            System.out.printf(Locale.ROOT, "Query time: %.3f ms%n", (t1 - t0) / 1e6);
            return;
        }

        Object label = props.getOrDefault("label", "");
        System.out.println("Label: " + label);

        props.entrySet().stream()
                .filter(e -> !e.getKey().equals("id") && !e.getKey().equals("label"))
                .sorted(Map.Entry.comparingByKey())
                .forEach(e -> System.out.println("  " + e.getKey() + " = " + e.getValue()));
        
        long t1 = System.nanoTime();
        System.out.printf(Locale.ROOT, "Query time: %.3f ms%n", (t1 - t0) / 1e6);
    }

    // -gl <label>  
    public static void queryEdgeIdsByLabel(Session session, String label) {
        System.out.println("Querying edges with Label: " + label);
        long t0 = System.nanoTime();
        
        long[] count = new long[1];
        long total = forEachEdgeIdByLabel(session, label, eid -> {
            count[0]++;
            if (count[0] <= 10) {
                System.out.println("  Found Edge ID: " + eid);
            }
        });
        if (total > 10) {
            System.out.println("  ... (total " + total + ")");
        }
        
        long t1 = System.nanoTime();
        System.out.printf(Locale.ROOT, "Total edges: %,d. Query time: %.3f ms%n", total, (t1 - t0) / 1e6);
    }

    // -nv <key=value> 
    public static void queryNodesByPropEquals(Session session, String key, String value) {
        System.out.println("Querying nodes where " + key + " = " + value);
        long t0 = System.nanoTime();
        
        long[] count = new long[1];
        long total = forEachNodeByPropertyEquals(session, key, value, nid -> {
            count[0]++;
            if (count[0] <= 10) {
                System.out.println("  Found Node ID: " + nid);
            }
        });
        if (total > 10) {
            System.out.println("  ... (total " + total + ")");
        }
        
        long t1 = System.nanoTime();
        System.out.printf(Locale.ROOT, "Total nodes: %,d. Query time: %.3f ms%n", total, (t1 - t0) / 1e6);
    }

    // helpers

    public static String nonNull(String s){ return (s == null) ? "" : s; }
    
    public static String safe(String[] a, Integer i){
        if (i == null || i < 0 || i >= a.length) return "";
        String s = a[i];
        return s == null ? "" : s;
    }
    
    public static String makeEdgeId(String src, String label, String dst) {
        String s = src + "|" + label + "|" + dst;
        long x = 1125899906842597L;
        for (int i=0;i<s.length();i++) x = (x * 1315423911L) ^ s.charAt(i);
        return Long.toUnsignedString(x);
    }

    public static String relType(String label) {
        String norm = label.replaceAll("[^A-Z0-9_]", "_");
        if (norm.isEmpty()) norm = "REL";
        if (Character.isDigit(norm.charAt(0))) norm = "_" + norm;
        return norm;
    }
    
    public static void clearDatabase(Session session) {
        System.out.println("Preparing DB for ingest (Clear)...");
        long total = 0;
        final int LIMIT = 5000; 

        while (true) {
            Result r = session.run("""
                MATCH (n)
                WITH n LIMIT $limit
                DETACH DELETE n
                RETURN count(*) AS c
            """, parameters("limit", LIMIT));

            long c = r.single().get("c").asLong();
            total += c;
            if (c == 0) break;
            System.out.printf(Locale.ROOT, "  deleted in this step: %,d (total: %,d)%n", c, total);
        }
        System.out.println("Database cleared.");
    }
}