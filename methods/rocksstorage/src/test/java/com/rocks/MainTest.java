package com.rocks;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.io.File;
import java.nio.file.Files;
import java.util.HashSet;
import java.util.Set;

import static org.junit.Assert.*;

public class MainTest {

    @Rule
    public TemporaryFolder tempFolder = new TemporaryFolder();

    @Test
    public void testIngestAndQueries() throws Exception {
        File dbDir = tempFolder.newFolder("rocksdb_test");
        File nodesFile = tempFolder.newFile("nodes.pgdf");
        File edgesFile = tempFolder.newFile("edges.pgdf");

        // Write small dataset
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

        try (Main store = Main.open(dbDir.toPath())) {
            // Test Ingestion
            store.ingestNodes(nodesFile.toPath());
            store.ingestEdges(edgesFile.toPath());

            // Test Q1: getNode
            Main.NodeBlob n1 = store.getNode("1");
            assertNotNull("Node 1 should exist", n1);
            assertEquals("Person", n1.label);
            assertEquals("Alice", n1.props.get("firstName"));
            assertEquals("Smith", n1.props.get("lastName"));
            assertEquals("female", n1.props.get("gender"));

            Main.NodeBlob n3 = store.getNode("3");
            assertNotNull("Node 3 should exist", n3);
            assertEquals("Comment", n3.label);
            assertEquals("Great post", n3.props.get("firstName"));
            assertFalse(n3.props.containsKey("lastName")); // empty prop not stored

            assertNull("Node 999 should not exist", store.getNode("999"));

            // Test Q2: forEachEdgeIdByLabel
            Set<String> knowsEdges = new HashSet<>();
            store.forEachEdgeIdByLabel("Knows", knowsEdges::add);
            assertEquals(Set.of("101", "103"), knowsEdges);

            Set<String> likesEdges = new HashSet<>();
            store.forEachEdgeIdByLabel("Likes", likesEdges::add);
            assertEquals(Set.of("102"), likesEdges);

            Set<String> nonExistentEdges = new HashSet<>();
            store.forEachEdgeIdByLabel("NonExistent", nonExistentEdges::add);
            assertTrue(nonExistentEdges.isEmpty());

            // Test Q3: forEachNodeByPropertyEquals
            Set<String> femaleNodes = new HashSet<>();
            store.forEachNodeByPropertyEquals("gender", "female", femaleNodes::add);
            assertEquals(Set.of("1", "3"), femaleNodes);

            Set<String> aliceNodes = new HashSet<>();
            store.forEachNodeByPropertyEquals("firstName", "Alice", aliceNodes::add);
            assertEquals(Set.of("1"), aliceNodes);

            Set<String> nonExistentProp = new HashSet<>();
            store.forEachNodeByPropertyEquals("firstName", "NonExistent", nonExistentProp::add);
            assertTrue(nonExistentProp.isEmpty());

            // Test prefix collision prevention (e.g. length=2 vs length=20)
            File prefixNodesFile = tempFolder.newFile("prefix_nodes.pgdf");
            File prefixEdgesFile = tempFolder.newFile("prefix_edges.pgdf");
            Files.writeString(prefixNodesFile.toPath(),
                    "@id|@label|length\n" +
                    "10|Post|2\n" +
                    "20|Post|20\n" +
                    "25|Post|25\n"
            );
            Files.writeString(prefixEdgesFile.toPath(), "@id|@out|@label|@in|@dir\n");
            store.ingestNodes(prefixNodesFile.toPath());

            Set<String> len2Nodes = new HashSet<>();
            store.forEachNodeByPropertyEquals("length", "2", len2Nodes::add);
            assertEquals("Exact match should only return node 10 with length=2", Set.of("10"), len2Nodes);

            Set<String> len20Nodes = new HashSet<>();
            store.forEachNodeByPropertyEquals("length", "20", len20Nodes::add);
            assertEquals("Exact match should only return node 20 with length=20", Set.of("20"), len20Nodes);

            // Test benchmarking method runs without exceptions
            File idsFile = tempFolder.newFile("ids.txt");
            File labelsFile = tempFolder.newFile("labels.txt");
            File propsFile = tempFolder.newFile("props.txt");

            Files.writeString(idsFile.toPath(), "1\n2\n999\n");
            Files.writeString(labelsFile.toPath(), "Knows\nLikes\nNonExistent\n");
            Files.writeString(propsFile.toPath(), "gender=female\nfirstName=Alice\nunknown=val\n");

            store.benchmarking(idsFile.toPath(), labelsFile.toPath(), propsFile.toPath());
        }
    }
}
