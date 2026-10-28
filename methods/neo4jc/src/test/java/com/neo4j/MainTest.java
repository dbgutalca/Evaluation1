package com.neo4j;

import org.junit.Assume;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;
import org.neo4j.driver.AuthTokens;
import org.neo4j.driver.Driver;
import org.neo4j.driver.GraphDatabase;
import org.neo4j.driver.Session;

import java.io.File;
import java.nio.file.Files;
import java.util.*;

import static org.junit.Assert.*;

public class MainTest {

    @Rule
    public TemporaryFolder tempFolder = new TemporaryFolder();

    @Test
    public void testIngestAndQueries() throws Exception {
        String uri  = System.getProperty("neo4j.uri", System.getenv().getOrDefault("NEO4J_URI", "bolt://localhost:7687"));
        String user = System.getProperty("neo4j.user", System.getenv().getOrDefault("NEO4J_USER", "neo4j"));
        String pass = System.getProperty("neo4j.pass", System.getenv().getOrDefault("NEO4J_PASS", "password"));

        // Check if server is reachable before proceeding
        Driver driver = null;
        try {
            driver = GraphDatabase.driver(uri, AuthTokens.basic(user, pass));
            driver.verifyConnectivity();
        } catch (Exception e) {
            if (driver != null) {
                try { driver.close(); } catch (Exception ignore) {}
            }
            Assume.assumeTrue("Neo4j server not reachable at " + uri + ". Skipping test on this machine. Details: " + e.getMessage(), false);
            return;
        }

        try (Driver d = driver; Session session = d.session()) {
            File nodesFile = tempFolder.newFile("nodes.pgdf");
            File edgesFile = tempFolder.newFile("edges.pgdf");

            // Write small synthetic dataset
            Files.writeString(nodesFile.toPath(),
                    "@id|@label|firstName|lastName|gender\n" +
                    "1|Person|Alice|Smith|female\n" +
                    "2|Person|Bob|Jones|male\n" +
                    "3|Comment|Great post||female\n"
            );

            Files.writeString(edgesFile.toPath(),
                    "@id|@out|@label|@in|@dir\n" +
                    "101|1|Knows|2|T\n" +
                    "102|2|Likes|3|T\n" +
                    "103|1|Knows|3|T\n"
            );

            // 1. Ingest
            System.out.println("[TEST] Ingesting test graph into Neo4j...");
            Main.runIngest(session, nodesFile.toPath(), edgesFile.toPath());

            // 2. Q1: getNode
            System.out.println("[TEST] Testing Q1 (getNode)...");
            Map<String, Object> n1 = Main.getNode(session, "1");
            assertNotNull("Node 1 should exist", n1);
            assertEquals("Person", n1.get("label"));
            assertEquals("Alice", n1.get("firstName"));
            assertEquals("Smith", n1.get("lastName"));
            assertEquals("female", n1.get("gender"));

            Map<String, Object> n3 = Main.getNode(session, "3");
            assertNotNull("Node 3 should exist", n3);
            assertEquals("Comment", n3.get("label"));
            assertEquals("Great post", n3.get("firstName"));
            assertFalse("Empty prop should not be stored", n3.containsKey("lastName"));

            Map<String, Object> nMissing = Main.getNode(session, "999");
            assertNull("Node 999 should not exist", nMissing);

            // 3. Q2: forEachEdgeIdByLabel
            System.out.println("[TEST] Testing Q2 (forEachEdgeIdByLabel)...");
            Set<String> knowsEdges = new HashSet<>();
            long countKnows = Main.forEachEdgeIdByLabel(session, "Knows", knowsEdges::add);
            assertEquals(2L, countKnows);
            assertEquals(Set.of("101", "103"), knowsEdges);

            Set<String> likesEdges = new HashSet<>();
            long countLikes = Main.forEachEdgeIdByLabel(session, "Likes", likesEdges::add);
            assertEquals(1L, countLikes);
            assertEquals(Set.of("102"), likesEdges);

            Set<String> nonExistentEdges = new HashSet<>();
            long countNone = Main.forEachEdgeIdByLabel(session, "NonExistent", nonExistentEdges::add);
            assertEquals(0L, countNone);
            assertTrue(nonExistentEdges.isEmpty());

            // 4. Q3: forEachNodeByPropertyEquals
            System.out.println("[TEST] Testing Q3 (forEachNodeByPropertyEquals)...");
            Set<String> femaleNodes = new HashSet<>();
            long countFemale = Main.forEachNodeByPropertyEquals(session, "gender", "female", femaleNodes::add);
            assertEquals(2L, countFemale);
            assertEquals(Set.of("1", "3"), femaleNodes);

            Set<String> aliceNodes = new HashSet<>();
            long countAlice = Main.forEachNodeByPropertyEquals(session, "firstName", "Alice", aliceNodes::add);
            assertEquals(1L, countAlice);
            assertEquals(Set.of("1"), aliceNodes);

            Set<String> unknownNodes = new HashSet<>();
            long countUnknown = Main.forEachNodeByPropertyEquals(session, "firstName", "Unknown", unknownNodes::add);
            assertEquals(0L, countUnknown);
            assertTrue(unknownNodes.isEmpty());

            // 5. Benchmarking runner
            System.out.println("[TEST] Testing benchmarking runner...");
            File idsFile = tempFolder.newFile("ids.txt");
            File labelsFile = tempFolder.newFile("labels.txt");
            File propsFile = tempFolder.newFile("props.txt");

            Files.writeString(idsFile.toPath(), "1\n2\n999\n");
            Files.writeString(labelsFile.toPath(), "Knows\nLikes\nNonExistent\n");
            Files.writeString(propsFile.toPath(), "gender=female\nfirstName=Alice\nunknown=val\n");

            Main.benchmarking(session, idsFile.toPath(), labelsFile.toPath(), propsFile.toPath());

            // Clean database after test
            Main.clearDatabase(session);
            System.out.println("\n>>> ALL NEO4J TESTS PASSED SUCCESSFULLY! <<<");
        }
    }
}
