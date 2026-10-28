import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.Statement;
import java.util.*;

public class PostgresTest {

    private static void assertTrue(boolean condition, String msg) {
        if (!condition) {
            throw new AssertionError("ASSERTION FAILED: " + msg);
        }
    }

    private static void assertEquals(Object expected, Object actual, String msg) {
        if (!Objects.equals(expected, actual)) {
            throw new AssertionError("ASSERTION FAILED: " + msg + " (expected: " + expected + ", got: " + actual + ")");
        }
    }

    public static void main(String[] args) {
        String url  = args.length > 0 ? args[0] : System.getProperty("pg.url", System.getenv().getOrDefault("PG_URL", "jdbc:postgresql://localhost:5432/postgres"));
        String user = args.length > 1 ? args[1] : System.getProperty("pg.user", System.getenv().getOrDefault("PG_USER", "postgres"));
        String pass = args.length > 2 ? args[2] : System.getProperty("pg.pass", System.getenv().getOrDefault("PG_PASS", "postgres"));

        // Check if database is reachable before proceeding
        try (Connection testCx = DriverManager.getConnection(url, user, pass)) {
            // Connection successful
        } catch (java.sql.SQLException e) {
            String sqlState = e.getSQLState() != null ? e.getSQLState() : "";
            String msg = e.getMessage() != null ? e.getMessage() : "";
            if (sqlState.startsWith("08") || (msg.toLowerCase().contains("connection to") && msg.toLowerCase().contains("refused"))) {
                System.out.println("[SKIP] PostgreSQL server is not running on target host (" + msg.trim() + ").");
                System.out.println("Skipping PostgreSQL test on this machine.");
                return;
            }
            System.err.println("[ERROR] PostgreSQL connection failed: " + msg.trim());
            System.err.println("[ERROR] Server responded, but credentials or database name in PG_URL/PG_USER/PG_PASS might be wrong.");
            System.err.println("[ERROR] Target URL: " + url + " | User: " + user);
            System.exit(1);
        } catch (Exception e) {
            System.err.println("[ERROR] Unexpected error connecting to PostgreSQL: " + e.getMessage());
            System.exit(1);
        }

        System.out.println("Starting PostgreSQL Unit Tests against: " + url + " (user: " + user + ")...");

        Path tempDir = null;
        try (Connection cx = DriverManager.getConnection(url, user, pass)) {
            cx.setAutoCommit(false);

            tempDir = Files.createTempDirectory("pg_test_");
            Path nodesFile = tempDir.resolve("nodes.pgdf");
            Path edgesFile = tempDir.resolve("edges.pgdf");

            // Write small synthetic dataset
            Files.writeString(nodesFile,
                    "@id|@label|firstName|lastName|gender\n" +
                    "1|Person|Alice|Smith|female\n" +
                    "2|Person|Bob|Jones|male\n" +
                    "3|Comment|Great post||female\n"
            );

            Files.writeString(edgesFile,
                    "@id|@out|@label|@in|@dir\n" +
                    "101|1|Knows|2|T\n" +
                    "102|2|Likes|3|T\n" +
                    "103|1|Knows|3|T\n"
            );

            // Clean database state before test
            try (Statement st = cx.createStatement()) {
                st.execute("DROP TABLE IF EXISTS edge_properties CASCADE;");
                st.execute("DROP TABLE IF EXISTS edges CASCADE;");
                st.execute("DROP TABLE IF EXISTS node_properties CASCADE;");
                st.execute("DROP TABLE IF EXISTS nodes CASCADE;");
            }
            cx.commit();

            // 1. Ingestion
            System.out.println("[TEST] Running Ingestion...");
            PostgresColumns.runIngest(cx, nodesFile, edgesFile);

            // 2. Q1: getNode
            System.out.println("[TEST] Testing Q1 (getNode)...");
            PostgresColumns.NodeData n1 = PostgresColumns.getNode(cx, "1");
            assertTrue(n1 != null, "Node '1' should exist");
            assertEquals("Person", n1.label, "Node 1 label");
            assertEquals("Alice", n1.props.get("firstName"), "Node 1 firstName");
            assertEquals("Smith", n1.props.get("lastName"), "Node 1 lastName");
            assertEquals("female", n1.props.get("gender"), "Node 1 gender");

            PostgresColumns.NodeData n3 = PostgresColumns.getNode(cx, "3");
            assertTrue(n3 != null, "Node '3' should exist");
            assertEquals("Comment", n3.label, "Node 3 label");
            assertEquals("Great post", n3.props.get("firstName"), "Node 3 firstName");
            assertTrue(!n3.props.containsKey("lastName"), "Node 3 should not have empty prop");

            PostgresColumns.NodeData nMissing = PostgresColumns.getNode(cx, "999");
            assertTrue(nMissing == null, "Node '999' should not exist");

            // 3. Q2: forEachEdgeIdByLabel
            System.out.println("[TEST] Testing Q2 (forEachEdgeIdByLabel)...");
            Set<String> knowsEdges = new HashSet<>();
            long countKnows = PostgresColumns.forEachEdgeIdByLabel(cx, "Knows", knowsEdges::add);
            assertEquals(2L, countKnows, "Knows edges count");
            assertEquals(Set.of("101", "103"), knowsEdges, "Knows edge IDs");

            Set<String> likesEdges = new HashSet<>();
            long countLikes = PostgresColumns.forEachEdgeIdByLabel(cx, "Likes", likesEdges::add);
            assertEquals(1L, countLikes, "Likes edges count");
            assertEquals(Set.of("102"), likesEdges, "Likes edge IDs");

            Set<String> nonExistentEdges = new HashSet<>();
            long countNone = PostgresColumns.forEachEdgeIdByLabel(cx, "NonExistent", nonExistentEdges::add);
            assertEquals(0L, countNone, "NonExistent label count");
            assertTrue(nonExistentEdges.isEmpty(), "NonExistent edges should be empty");

            // 4. Q3: forEachNodeByPropertyEquals
            System.out.println("[TEST] Testing Q3 (forEachNodeByPropertyEquals)...");
            Set<String> femaleNodes = new HashSet<>();
            long countFemale = PostgresColumns.forEachNodeByPropertyEquals(cx, "gender", "female", femaleNodes::add);
            assertEquals(2L, countFemale, "Nodes with gender=female count");
            assertEquals(Set.of("1", "3"), femaleNodes, "Matching node IDs for gender=female");

            Set<String> aliceNodes = new HashSet<>();
            long countAlice = PostgresColumns.forEachNodeByPropertyEquals(cx, "firstName", "Alice", aliceNodes::add);
            assertEquals(1L, countAlice, "Nodes with firstName=Alice count");
            assertEquals(Set.of("1"), aliceNodes, "Matching node IDs for firstName=Alice");

            Set<String> unknownNodes = new HashSet<>();
            long countUnknown = PostgresColumns.forEachNodeByPropertyEquals(cx, "firstName", "Unknown", unknownNodes::add);
            assertEquals(0L, countUnknown, "Nodes with non-existent property value");
            assertTrue(unknownNodes.isEmpty(), "Unknown property should return empty");

            // 5. Test benchmarking
            System.out.println("[TEST] Testing benchmarking runner...");
            Path idsPath = tempDir.resolve("ids.txt");
            Path labelsPath = tempDir.resolve("labels.txt");
            Path propsPath = tempDir.resolve("props.txt");

            Files.writeString(idsPath, "1\n2\n999\n");
            Files.writeString(labelsPath, "Knows\nLikes\nNonExistent\n");
            Files.writeString(propsPath, "gender=female\nfirstName=Alice\nunknown=val\n");

            PostgresColumns.benchmarking(cx, idsPath, labelsPath, propsPath);

            // Clean database state after test
            try (Statement st = cx.createStatement()) {
                st.execute("DROP TABLE IF EXISTS edge_properties CASCADE;");
                st.execute("DROP TABLE IF EXISTS edges CASCADE;");
                st.execute("DROP TABLE IF EXISTS node_properties CASCADE;");
                st.execute("DROP TABLE IF EXISTS nodes CASCADE;");
            }
            cx.commit();

            System.out.println("\n>>> ALL POSTGRESQL TESTS PASSED SUCCESSFULLY! <<<");

        } catch (Throwable t) {
            System.err.println("POSTGRESQL TEST FAILED!");
            t.printStackTrace();
            System.exit(1);
        } finally {
            if (tempDir != null) {
                try {
                    Files.walk(tempDir)
                            .sorted(Comparator.reverseOrder())
                            .map(Path::toFile)
                            .forEach(File::delete);
                } catch (Exception ignore) {}
            }
        }
    }
}
