import com.sparsity.sparksee.gdb.*;
import java.io.File;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.*;

public class SparkseeTest {

    private static void assertTrue(boolean condition, String msg) {
        if (!condition) {
            throw new AssertionError("ASSERTION FAILED: " + msg);
        }
    }

    private static void assertEquals(Object expected, Object actual, String msg) {
        if (!java.util.Objects.equals(expected, actual)) {
            throw new AssertionError("ASSERTION FAILED: " + msg + " (expected: " + expected + ", got: " + actual + ")");
        }
    }

    public static void main(String[] args) {
        System.out.println("Starting Sparksee Unit Tests...");

        Path tempDir = null;
        try {
            tempDir = Files.createTempDirectory("sparksee_test_");
            Path nodesFile = tempDir.resolve("nodes.pgdf");
            Path edgesFile = tempDir.resolve("edges.pgdf");
            Path dbPath = tempDir.resolve("test_sparksee.gdb");

            // Write test data
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

            SparkseeImplementation2 app = new SparkseeImplementation2();

            // 1. Ingest
            System.out.println("[TEST] Ingesting test graph...");
            app.runIngest(nodesFile.toString(), edgesFile.toString(), dbPath.toString());
            assertTrue(Files.exists(dbPath), "Database file should exist after ingest");

            // 2. Query validation
            SparkseeConfig cfg = new SparkseeConfig("sparksee.cfg");
            Sparksee sparksee = new Sparksee(cfg);
            Database db = sparksee.open(dbPath.toString(), true);
            Session sess = db.newSession();
            Graph g = sess.getGraph();

            try {
                int extIdAttr = g.findAttribute(Type.NodesType, "ext_id");
                assertTrue(extIdAttr != Attribute.InvalidAttribute, "'ext_id' attribute must exist");

                Value vArg = new Value();
                Value vRes = new Value();

                // Q1: getNode
                System.out.println("[TEST] Testing Q1 (getNode)...");
                long oid1 = app.getNode(g, extIdAttr, "1", vArg, vRes);
                assertTrue(oid1 != com.sparsity.sparksee.gdb.Objects.InvalidOID, "Node '1' should exist");

                long oid2 = app.getNode(g, extIdAttr, "2", vArg, vRes);
                assertTrue(oid2 != com.sparsity.sparksee.gdb.Objects.InvalidOID, "Node '2' should exist");

                long oidMissing = app.getNode(g, extIdAttr, "999", vArg, vRes);
                assertEquals(com.sparsity.sparksee.gdb.Objects.InvalidOID, oidMissing, "Node '999' should not exist");

                // Q2: forEachEdgeIdByLabel
                System.out.println("[TEST] Testing Q2 (forEachEdgeIdByLabel)...");
                Set<String> knowsEdges = new HashSet<>();
                long countKnows = app.forEachEdgeIdByLabel(g, "Knows", vRes, knowsEdges::add);
                assertEquals(2L, countKnows, "Knows edges count");
                assertEquals(Set.of("101", "103"), knowsEdges, "Knows edge IDs");

                Set<String> likesEdges = new HashSet<>();
                long countLikes = app.forEachEdgeIdByLabel(g, "Likes", vRes, likesEdges::add);
                assertEquals(1L, countLikes, "Likes edges count");
                assertEquals(Set.of("102"), likesEdges, "Likes edge IDs");

                Set<String> nonExistentEdges = new HashSet<>();
                long countNone = app.forEachEdgeIdByLabel(g, "NonExistent", vRes, nonExistentEdges::add);
                assertEquals(0L, countNone, "NonExistent label count");
                assertTrue(nonExistentEdges.isEmpty(), "NonExistent edges should be empty");

                // Q3: forEachNodeByPropertyEquals
                System.out.println("[TEST] Testing Q3 (forEachNodeByPropertyEquals)...");
                TypeList tList = g.findNodeTypes();
                List<Integer> allNodeTypes = new ArrayList<>();
                TypeListIterator tIt = tList.iterator();
                while (tIt.hasNext()) allNodeTypes.add(tIt.next());

                Set<Long> femaleOids = new HashSet<>();
                long countFemale = app.forEachNodeByPropertyEquals(g, allNodeTypes, "gender", "female", vArg, femaleOids::add);
                assertEquals(2L, countFemale, "Nodes with gender=female count");
                assertEquals(Set.of(oid1, app.getNode(g, extIdAttr, "3", vArg, vRes)), femaleOids, "Matching OIDs for gender=female");

                Set<Long> aliceOids = new HashSet<>();
                long countAlice = app.forEachNodeByPropertyEquals(g, allNodeTypes, "firstName", "Alice", vArg, aliceOids::add);
                assertEquals(1L, countAlice, "Nodes with firstName=Alice count");
                assertEquals(Set.of(oid1), aliceOids, "Matching OIDs for firstName=Alice");

                long countUnknown = app.forEachNodeByPropertyEquals(g, allNodeTypes, "firstName", "Unknown", vArg, null);
                assertEquals(0L, countUnknown, "Nodes with non-existent property value");

            } finally {
                sess.close();
                db.close();
                sparksee.close();
            }

            // 3. Test benchmarking execution
            System.out.println("[TEST] Testing benchmarking runner...");
            Path idsPath = tempDir.resolve("ids.txt");
            Path labelsPath = tempDir.resolve("labels.txt");
            Path propsPath = tempDir.resolve("props.txt");

            Files.writeString(idsPath, "1\n2\n999\n");
            Files.writeString(labelsPath, "Knows\nLikes\nNonExistent\n");
            Files.writeString(propsPath, "gender=female\nfirstName=Alice\nunknown=val\n");

            app.benchmarking(dbPath.toString(), idsPath, labelsPath, propsPath);

            System.out.println("\n>>> ALL SPARKSEE TESTS PASSED SUCCESSFULLY! <<<");

        } catch (Throwable t) {
            String msg = t.getMessage() != null ? t.getMessage() : t.toString();
            if (t instanceof UnsatisfiedLinkError || t instanceof NoClassDefFoundError || msg.toLowerCase().contains("license") || msg.toLowerCase().contains("sparksee.cfg")) {
                System.out.println("[SKIP] Sparksee environment not available on this machine (" + msg + ").");
                System.out.println("Skipping Sparksee test on this machine.");
                return;
            }
            System.err.println("SPARKSEE TEST FAILED!");
            t.printStackTrace();
            System.exit(1);
        } finally {
            if (tempDir != null) {
                try {
                    // Recursive delete of temp directory
                    Files.walk(tempDir)
                            .sorted(Comparator.reverseOrder())
                            .map(Path::toFile)
                            .forEach(File::delete);
                } catch (Exception ignore) {}
            }
        }
    }
}
