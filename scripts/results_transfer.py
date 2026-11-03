#!/usr/bin/env python3
"""
Results Transfer Tool (Sender & Receiver)
=========================================
A self-contained, zero-dependency utility to transfer experiment result folders
over HTTP. Designed for restricted environments.

Features:
  - Standard library only: requires no third-party packages.
  - Dynamic URL resolution: URL can be passed via CLI flag, RECEIVER_URL environment
    variable, or benchmark.properties.
  - In-memory ZIP packaging: does not generate temporary files on disk.
  - Safe extraction: protects against directory traversal (Zip Slip).
  - Optional shared-secret token for secure exposure via tunneling.

Usage:
  1. On your LOCAL machine (Receiver):
     python3 scripts/results_transfer.py receive --port 8080 --output ./received_results --token secret123

  2. On the REMOTE VM (Sender):
     python3 scripts/results_transfer.py send --url https://<FORWARDED_URL>/upload --dir results --token secret123
     # Or using environment variables:
     export RECEIVER_URL="https://<FORWARDED_URL>/upload"
     export RECEIVER_TOKEN="secret123"
     python3 scripts/results_transfer.py send --tag sf1
"""

import argparse
import io
import os
import sys
import time
import zipfile
from http.server import HTTPServer, BaseHTTPRequestHandler
import urllib.request
import urllib.error


def zip_directory_to_bytes(source_dir: str) -> bytes:
    """Compress an entire directory tree into an in-memory ZIP archive."""
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w', zipfile.ZIP_DEFLATED) as zf:
        for root, _, files in os.walk(source_dir):
            for file in files:
                abs_path = os.path.join(root, file)
                rel_path = os.path.relpath(abs_path, source_dir)
                zf.write(abs_path, rel_path)
    buffer.seek(0)
    return buffer.getvalue()


def safe_extract_zip(zip_bytes: bytes, target_dir: str) -> int:
    """Extract an in-memory ZIP archive while strictly preventing directory traversal."""
    os.makedirs(target_dir, exist_ok=True)
    target_abs = os.path.abspath(target_dir)
    extracted_count = 0

    with zipfile.ZipFile(io.BytesIO(zip_bytes), 'r') as zf:
        for member in zf.infolist():
            dest = os.path.abspath(os.path.join(target_dir, member.filename))
            if not dest.startswith(target_abs + os.sep) and dest != target_abs:
                raise ValueError(f"Directory traversal detected in archive entry: {member.filename}")
            zf.extract(member, target_dir)
            extracted_count += 1

    return extracted_count


def load_property_from_file(prop_name: str, config_file: str = "benchmark.properties") -> str:
    """Read a property value from benchmark.properties if present."""
    if os.path.isfile(config_file):
        try:
            with open(config_file, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line.startswith(f"{prop_name}=") or line.startswith(f"{prop_name} ="):
                        return line.split("=", 1)[1].strip()
        except Exception:
            pass
    return ""


def create_receiver_handler(output_base: str, auth_token: str = None, single_transfer: bool = False):
    class ReceiverHandler(BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            sys.stdout.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {format % args}\n")
            sys.stdout.flush()

        def do_GET(self):
            if self.path == "/health":
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.end_headers()
                self.wfile.write(b"OK\n")
            else:
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.end_headers()
                self.wfile.write(b"Results Receiver is online. Submit data via POST /upload.\n")

        def do_POST(self):
            if not self.path.startswith("/upload"):
                msg = b"Endpoint Not Found. Use POST /upload\n"
                self.send_response(404)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(msg)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(msg)
                self.wfile.flush()
                return

            if auth_token:
                client_token = self.headers.get("X-Auth-Token")
                if client_token != auth_token:
                    msg = b"Forbidden: Invalid or missing authentication token\n"
                    self.send_response(403)
                    self.send_header("Content-Type", "text/plain")
                    self.send_header("Content-Length", str(len(msg)))
                    self.send_header("Connection", "close")
                    self.end_headers()
                    self.wfile.write(msg)
                    self.wfile.flush()
                    self.log_message("Rejected upload: Invalid or missing X-Auth-Token")
                    return

            try:
                content_len = int(self.headers.get('Content-Length', 0))
                if content_len <= 0:
                    msg = b"Bad Request: Empty payload\n"
                    self.send_response(400)
                    self.send_header("Content-Type", "text/plain")
                    self.send_header("Content-Length", str(len(msg)))
                    self.send_header("Connection", "close")
                    self.end_headers()
                    self.wfile.write(msg)
                    self.wfile.flush()
                    return

                self.log_message(f"Receiving {content_len:,} bytes of compressed payload...")
                zip_bytes = self.rfile.read(content_len)

                tag = self.headers.get("X-Dataset-Tag", "results").replace("/", "_").replace("\\", "_")
                timestamp = time.strftime('%Y%m%d_%H%M%S')
                dest_dir = os.path.join(output_base, f"{tag}_{timestamp}")

                count = safe_extract_zip(zip_bytes, dest_dir)
                self.log_message(f"Successfully extracted {count} files to: {dest_dir}")

                resp_bytes = f"SUCCESS: {count} files saved to {dest_dir}\n".encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(resp_bytes)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(resp_bytes)
                self.wfile.flush()

                if single_transfer:
                    self.log_message("Single-transfer flag set. Terminating receiver server.")
                    import threading
                    threading.Thread(target=self.server.shutdown).start()

            except Exception as e:
                err_msg = f"Internal Error: {str(e)}\n".encode("utf-8")
                self.send_response(500)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(err_msg)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(err_msg)
                self.wfile.flush()
                self.log_message(f"Error handling upload: {str(e)}")

    return ReceiverHandler


def run_receiver(host: str, port: int, output_dir: str, token: str = None, single: bool = False):
    handler_class = create_receiver_handler(output_dir, token, single)
    server = HTTPServer((host, port), handler_class)
    print("=" * 70)
    print(f"  RESULTS RECEIVER ACTIVE AT http://{host}:{port}")
    print(f"  Target directory   : {os.path.abspath(output_dir)}")
    print(f"  Authentication     : {'ENABLED' if token else 'DISABLED'}")
    print(f"  Upload endpoint    : http://{host}:{port}/upload")
    print("=" * 70)
    print("Waiting for incoming results from VMs... (Press Ctrl+C to stop)\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping receiver server...")
    finally:
        server.server_close()
        print("Receiver closed cleanly.")


def run_sender(url: str, source_dir: str, token: str = None, tag: str = None):
    if not os.path.isdir(source_dir):
        print(f"[ERROR] Source directory does not exist: {source_dir}", file=sys.stderr)
        sys.exit(1)

    print("=" * 70)
    print("  PACKAGING AND TRANSMITTING EXPERIMENT RESULTS")
    print(f"  Source directory : {os.path.abspath(source_dir)}")
    print(f"  Target endpoint  : {url}")
    print("=" * 70)

    print("Compressing results folder in memory...")
    zip_bytes = zip_directory_to_bytes(source_dir)
    size_mb = len(zip_bytes) / (1024 * 1024)
    print(f"Payload size: {len(zip_bytes):,} bytes ({size_mb:.2f} MB)")

    headers = {
        "Content-Type": "application/zip",
        "Content-Length": str(len(zip_bytes)),
        "Connection": "close",
        "X-Dataset-Tag": tag or os.path.basename(os.path.abspath(source_dir))
    }
    if token:
        headers["X-Auth-Token"] = token

    req = urllib.request.Request(url, data=zip_bytes, headers=headers, method="POST")

    print(f"Uploading payload to {url}...")
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            elapsed = time.time() - t0
            status_code = resp.status
            body = resp.read().decode("utf-8").strip()
            print("\n[SUCCESS] Response from Receiver:")
            print(f"Status  : {status_code}")
            print(f"Elapsed : {elapsed:.2f}s")
            print(f"Details : {body}")
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")
        print(f"\n[ERROR] HTTP Error {e.code}: {e.reason}", file=sys.stderr)
        print(f"Server response: {err_body}", file=sys.stderr)
        sys.exit(2)
    except urllib.error.URLError as e:
        print(f"\n[ERROR] Network error: Could not reach {url}", file=sys.stderr)
        print(f"Reason: {e.reason}", file=sys.stderr)
        sys.exit(3)


def main():
    parser = argparse.ArgumentParser(
        description="Unified Results Transfer Tool (HTTP Sender & Receiver)",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )
    subparsers = parser.add_subparsers(dest="mode", required=True, help="Operating mode")

    # Receiver parser
    recv_p = subparsers.add_parser("receive", help="Run local HTTP receiver server")
    recv_p.add_argument("--host", default="0.0.0.0", help="Host address to bind (default: 0.0.0.0)")
    recv_p.add_argument("--port", type=int, default=8080, help="Port to listen on (default: 8080)")
    recv_p.add_argument("--output", "-o", default="./received_results", help="Directory where received files will be unpacked")
    recv_p.add_argument("--token", "-t", default=os.environ.get("RECEIVER_TOKEN"), help="Authentication token (or RECEIVER_TOKEN env var)")
    recv_p.add_argument("--single", action="store_true", help="Automatically shut down after receiving one upload")

    # Sender parser
    send_p = subparsers.add_parser("send", help="Send results directory to receiver server")
    default_url = os.environ.get("RECEIVER_URL") or load_property_from_file("receiver_url")
    send_p.add_argument("--url", "-u", default=default_url, help="Receiver URL (e.g. https://.../upload, or via RECEIVER_URL / benchmark.properties)")
    send_p.add_argument("--dir", "-d", default="./results", help="Directory to send (default: ./results)")
    default_token = os.environ.get("RECEIVER_TOKEN") or load_property_from_file("receiver_token")
    send_p.add_argument("--token", "-t", default=default_token, help="Authentication token (or via RECEIVER_TOKEN / benchmark.properties)")
    send_p.add_argument("--tag", default=None, help="Tag for naming received folder (default: directory name or scale_factor)")

    args = parser.parse_args()

    if args.mode == "receive":
        run_receiver(args.host, args.port, args.output, args.token, args.single)
    elif args.mode == "send":
        if not args.url:
            print("[ERROR] No receiver URL specified. Pass --url, set RECEIVER_URL env var, or add receiver_url to benchmark.properties.", file=sys.stderr)
            sys.exit(1)
        tag = args.tag or load_property_from_file("scale_factor")
        run_sender(args.url, args.dir, args.token, tag)


if __name__ == "__main__":
    main()
