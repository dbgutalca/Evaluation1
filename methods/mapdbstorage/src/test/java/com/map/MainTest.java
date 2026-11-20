package com.map;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;
import org.mapdb.DataInput2;
import org.mapdb.DataOutput2;

import java.io.File;
import java.nio.file.Files;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

import static org.junit.Assert.*;

public class MainTest {

    @Rule
    public TemporaryFolder tempFolder = new TemporaryFolder();

    @Test
    public void testIngestAndQueries() throws Exception {
        File dbDir = tempFolder.newFolder("mapdb_test");
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
            assertFalse(n3.props.containsKey("lastName"));

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

    @Test
    public void testSerializersRoundTrip() throws Exception {
        // 1. Test NodeBlobSerializer
        Main.NodeBlob originalNode = new Main.NodeBlob("Person", Map.of("name", "Alice", "age", "30"));
        DataOutput2 out = new DataOutput2();
        Main.NODE_BLOB_SERIALIZER.serialize(out, originalNode);
        DataInput2 in = new DataInput2.ByteArray(out.copyBytes());
        Main.NodeBlob deserializedNode = Main.NODE_BLOB_SERIALIZER.deserialize(in, out.pos);
        assertEquals(originalNode.label, deserializedNode.label);
        assertEquals(originalNode.props, deserializedNode.props);
        assertEquals(originalNode, deserializedNode);

        // 2. Test EdgeBlobSerializer
        Main.EdgeBlob originalEdge = new Main.EdgeBlob("Knows", "node1", "node2");
        out = new DataOutput2();
        Main.EDGE_BLOB_SERIALIZER.serialize(out, originalEdge);
        in = new DataInput2.ByteArray(out.copyBytes());
        Main.EdgeBlob deserializedEdge = Main.EDGE_BLOB_SERIALIZER.deserialize(in, out.pos);
        assertEquals(originalEdge.label, deserializedEdge.label);
        assertEquals(originalEdge.src, deserializedEdge.src);
        assertEquals(originalEdge.dst, deserializedEdge.dst);
        assertEquals(originalEdge, deserializedEdge);

        // 3. Test KeyTupleSerializer (type 1: edge id by label)
        Main.KeyTuple originalTuple1 = new Main.KeyTuple("Knows", "edge_123");
        out = new DataOutput2();
        Main.KEY_TUPLE_SERIALIZER.serialize(out, originalTuple1);
        in = new DataInput2.ByteArray(out.copyBytes());
        Main.KeyTuple deserializedTuple1 = Main.KEY_TUPLE_SERIALIZER.deserialize(in, out.pos);
        assertEquals(originalTuple1, deserializedTuple1);
        assertEquals(0, Main.KEY_TUPLE_SERIALIZER.compare(originalTuple1, deserializedTuple1));

        // 4. Test KeyTupleSerializer (type 2: node id by property)
        Main.KeyTuple originalTuple2 = new Main.KeyTuple("gender", "female", "node_456");
        out = new DataOutput2();
        Main.KEY_TUPLE_SERIALIZER.serialize(out, originalTuple2);
        in = new DataInput2.ByteArray(out.copyBytes());
        Main.KeyTuple deserializedTuple2 = Main.KEY_TUPLE_SERIALIZER.deserialize(in, out.pos);
        assertEquals(originalTuple2, deserializedTuple2);
        assertEquals(0, Main.KEY_TUPLE_SERIALIZER.compare(originalTuple2, deserializedTuple2));
    }
}
