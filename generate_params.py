#!/usr/bin/env python3
import os
import glob
import random
import csv


### CONFIG

# Random seed
SEED = 42

# Number of IDs and props to generate
NUM_SAMPLES = 100

# Output folder
OUTPUT_DIR = "params"

INPUT_PATTERN = "sf*/Nodes.pgdf"
DYNAMIC_LABELS = {"COMMENT", "FORUM", "PERSON", "POST"}

# Header names to ignore as properties
IGNORED_HEADERS = {"@id", "@label", "id", "label"}
# ==============================================================================

def extract_sf_name(file_path):
    """
    Extracts the scale factor folder name (e.g. 'sf01', 'sf1', 'sf3').
    """
    parts = file_path.split(os.sep)
    for part in parts:
        if part.startswith("sf"):
            return part
    return "unknown"

def generate_params():
    random.seed(SEED)

    # Ensure output directory exists
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # Find all matching Nodes.pgdf files
    node_files = sorted(glob.glob(INPUT_PATTERN))

    if not node_files:
        print(f"No files found matching pattern '{INPUT_PATTERN}'", flush=True)
        return

    print(f"Found {len(node_files)} scale factor files.", flush=True)
    print(f"Random seed: {SEED}", flush=True)
    print(f"Dynamic labels allowed: {sorted(list(DYNAMIC_LABELS))}", flush=True)
    print(f"Samples requested per SF: {NUM_SAMPLES}", flush=True)
    print(f"Output directory: '{OUTPUT_DIR}'", flush=True)
    print("-" * 60, flush=True)

    for file_path in node_files:
        sf_name = extract_sf_name(file_path)
        ids_filename = os.path.join(OUTPUT_DIR, f"ids_{sf_name}")
        props_filename = os.path.join(OUTPUT_DIR, f"props_{sf_name}")

        reservoir = []
        eligible_count = 0
        current_headers = []
        id_idx = 0
        label_idx = 1

        with open(file_path, 'r', encoding='utf-8') as f:
            reader = csv.reader(f, delimiter='|')

            for row in reader:
                if not row:
                    continue

                # Check for header line
                if row[0].strip().startswith("@id"):
                    current_headers = [c.strip() for c in row]
                    for idx, col in enumerate(current_headers):
                        if col == "@id":
                            id_idx = idx
                        elif col == "@label":
                            label_idx = idx
                    continue

                if len(row) <= max(id_idx, label_idx):
                    continue

                node_id = row[id_idx].strip()
                node_label = row[label_idx].strip()

                # Process only nodes belonging to dynamic labels
                if node_label in DYNAMIC_LABELS:
                    # Extract candidate properties:
                    # Exclude header metadata, empty values, and values equal to the node's ID
                    properties = []
                    for idx, val in enumerate(row):
                        if idx < len(current_headers):
                            header_name = current_headers[idx]
                            val_clean = val.strip()

                            is_metadata_header = header_name.startswith("@") or header_name.lower() in IGNORED_HEADERS
                            is_same_as_id = (val_clean == node_id)

                            if not is_metadata_header and not is_same_as_id and val_clean != "":
                                properties.append((header_name, val_clean))

                    if properties:
                        eligible_count += 1
                        item = (node_id, properties)

                        if len(reservoir) < NUM_SAMPLES:
                            reservoir.append(item)
                        else:
                            r = random.randint(0, eligible_count - 1)
                            if r < NUM_SAMPLES:
                                reservoir[r] = item

        print(f"[{sf_name}] Eligible dynamic nodes: {eligible_count:,}", flush=True)

        if eligible_count == 0:
            print(f"  -> Warning: No eligible nodes found in {file_path}", flush=True)
            continue

        # Write output files 
        with open(ids_filename, 'w', encoding='utf-8') as f_ids, \
             open(props_filename, 'w', encoding='utf-8') as f_props:

            for node_id, props in reservoir:
                # Randomly select one property for this node
                prop_name, prop_val = random.choice(props)

                f_ids.write(f"{node_id}\n")
                f_props.write(f"{prop_name}={prop_val}\n")

        print(f"  -> Generated {len(reservoir)} IDs   : {ids_filename}", flush=True)
        print(f"  -> Generated {len(reservoir)} Props : {props_filename}", flush=True)

    print("-" * 60, flush=True)
    print(f"Param generation complete. All files saved to '{OUTPUT_DIR}/'.", flush=True)

if __name__ == "__main__":
    generate_params()
