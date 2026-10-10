"""ARKit whole-frame TCP receiver, protocol ILD2. Replaces the legacy receiver.
Run: python ios_driver.py   (requires Pillow: python -m pip install pillow)
"""
import argparse
import io
import json
import math
import os
from pathlib import Path
import shutil
import socket
import struct
import tempfile
import uuid

from PIL import Image

MAGIC = b'ILD2'
HEADER = struct.Struct('>4sIIII')
LIMITS = (65536, 16 * 1024 * 1024, 4 * 1024 * 1024, 1024 * 1024)


def receive_exact(sock, length):
    data = bytearray()
    while len(data) < length:
        block = sock.recv(min(length - len(data), 65536))
        if not block:
            raise EOFError('Connection ended before the next complete frame.')
        data.extend(block)
    return bytes(data)


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def matrix(value, size):
    return (isinstance(value, list) and len(value) == size
            and all(isinstance(row, list) and len(row) == size
                    and all(finite(x) for x in row) for row in value))


def validate(meta, rgb, depth, confidence):
    if not isinstance(meta, dict) or meta.get('schema_version') != 2:
        raise ValueError('Expected schema_version 2.')
    rid = meta.get('recording_id')
    if not isinstance(rid, str) or str(uuid.UUID(rid)).upper() != rid.upper():
        raise ValueError('Invalid recording UUID.')
    fid = meta.get('frame_id')
    if type(fid) is not int or not 0 <= fid <= 999999999:
        raise ValueError('Invalid frame ID.')
    for key in ('rgb_width', 'rgb_height', 'depth_width', 'depth_height'):
        value = meta.get(key)
        if type(value) is not int or not 0 < value <= 8192:
            raise ValueError(f'Invalid {key}.')
    if meta.get('depth_dtype') != 'float32' or meta.get('depth_byte_order') != 'little' or meta.get('depth_units') != 'meters':
        raise ValueError('Expected little-endian Float32 depth in meters.')
    if len(depth) != meta['depth_width'] * meta['depth_height'] * 4:
        raise ValueError('Depth byte count does not match dimensions.')
    if meta.get('rgb_file') != 'rgb.jpg' or meta.get('depth_file') != 'depth.bin':
        raise ValueError('Unexpected payload filenames.')
    if confidence:
        if (meta.get('confidence_file') != 'confidence.bin'
                or meta.get('confidence_dtype') != 'uint8'
                or meta.get('confidence_width') != meta['depth_width']
                or meta.get('confidence_height') != meta['depth_height']
                or len(confidence) != meta['depth_width'] * meta['depth_height']):
            raise ValueError('Confidence layout mismatch.')
        if max(confidence) > 2:
            raise ValueError('Invalid confidence value.')
    elif 'confidence_file' in meta:
        raise ValueError('Confidence declared but missing.')
    for key in ('timestamp_seconds', 'elapsed_seconds'):
        if not finite(meta.get(key)) or meta[key] < 0:
            raise ValueError(f'Invalid {key}.')
    pose = meta.get('camera_to_world_4x4')
    k = meta.get('camera_intrinsics_3x3')
    if not matrix(pose, 4) or not matrix(k, 3):
        raise ValueError('Missing or nonfinite pose/intrinsics.')
    if meta.get('matrix_serialization') != 'rows':
        raise ValueError('Expected matrix rows.')
    if any(abs(a-b) > 1e-4 for a, b in zip(pose[3], [0, 0, 0, 1])):
        raise ValueError('Invalid pose last row.')
    for i in range(3):
        for j in range(3):
            dot = sum(pose[r][i] * pose[r][j] for r in range(3))
            if abs(dot - int(i == j)) > 0.01:
                raise ValueError('Pose rotation is not orthonormal.')
    determinant = sum(pose[0][i] * (pose[1][(i+1)%3]*pose[2][(i+2)%3]
                                  - pose[1][(i+2)%3]*pose[2][(i+1)%3]) for i in range(3))
    if abs(determinant - 1) > 0.01:
        raise ValueError('Pose rotation is not right-handed.')
    if k[0][0] <= 0 or k[1][1] <= 0:
        raise ValueError('Invalid focal length.')
    if (meta.get('intrinsics_reference_width') != meta['rgb_width']
            or meta.get('intrinsics_reference_height') != meta['rgb_height']):
        raise ValueError('Intrinsics reference does not match native RGB dimensions.')
    pos = meta.get('position_meters')
    if not isinstance(pos, dict) or any(not finite(pos.get(axis)) or abs(pos[axis]-pose[i][3]) > 1e-4
                                        for i, axis in enumerate(('x', 'y', 'z'))):
        raise ValueError('Position does not match pose.')
    q = meta.get('rotation_quaternion_xyzw')
    if not isinstance(q, list) or len(q) != 4 or not all(finite(x) for x in q) or abs(sum(x*x for x in q)-1) > 0.01:
        raise ValueError('Invalid quaternion.')
    if meta.get('tracking_state') not in ('normal', 'limited', 'unavailable'):
        raise ValueError('Missing tracking state.')
    # Verify payload really is a decodable JPEG with the declared dimensions.
    with Image.open(io.BytesIO(rgb)) as image:
        if image.format != 'JPEG' or image.size != (meta['rgb_width'], meta['rgb_height']):
            raise ValueError('RGB format or dimensions mismatch.')
        image.load()
    return rid, fid


def save_frame(root, meta, rgb, depth, confidence):
    rid, fid = validate(meta, rgb, depth, confidence)
    destination = root / rid / f'frame_{fid:06d}'
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        raise ValueError('Duplicate frame; refusing to overwrite.')
    temporary = Path(tempfile.mkdtemp(prefix='.partial_', dir=destination.parent))
    try:
        files = {'rgb.jpg': rgb, 'depth.bin': depth,
                 'metadata.json': json.dumps(meta, indent=2, allow_nan=False).encode('utf-8')}
        if confidence:
            files['confidence.bin'] = confidence
        for name, contents in files.items():
            with (temporary / name).open('wb') as output:
                output.write(contents)
                output.flush()
                os.fsync(output.fileno())
        temporary.rename(destination)
    except BaseException:
        shutil.rmtree(temporary, ignore_errors=True)
        raise
    return destination


def handle_client(sock, root):
    sock.settimeout(60)
    sock.sendall(MAGIC)
    last_recording = None
    last_id = -1
    last_time = -1.0
    while True:
        # An idle connection can stay open; incomplete frames time out.
        sock.settimeout(None)
        first = receive_exact(sock, 1)
        sock.settimeout(30)
        header = first + receive_exact(sock, HEADER.size - 1)
        magic, *sizes = HEADER.unpack(header)
        if magic != MAGIC:
            raise ValueError('Legacy/unknown sender. Run the updated ARKit screen.')
        if any(n > limit for n, limit in zip(sizes, LIMITS)) or any(n == 0 for n in sizes[:3]):
            raise ValueError('Invalid or excessive frame lengths.')
        json_bytes, rgb, depth, confidence = [receive_exact(sock, n) for n in sizes]
        meta = json.loads(json_bytes)
        rid, fid = validate(meta, rgb, depth, confidence)
        if rid == last_recording and (fid <= last_id or meta['timestamp_seconds'] <= last_time):
            raise ValueError('Nonmonotonic frame ID or timestamp.')
        path = save_frame(root, meta, rgb, depth, confidence)
        last_recording, last_id, last_time = rid, fid, meta['timestamp_seconds']
        sock.sendall(b'\x06')  # ACK only after successful validation and saving.
        print(f'[saved] {path} tracking={meta["tracking_state"]}', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default='0.0.0.0')
    parser.add_argument('--port', type=int, default=5678)
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parent / 'uploads')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    # Single active phone by design: bounded server memory and no competing writers.
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((args.host, args.port))
        server.listen(1)
        print(f'Listening on {args.host}:{args.port}\nSaving to {args.output.resolve()}', flush=True)
        try:
            while True:
                client, address = server.accept()
                print(f'Connected: {address}', flush=True)
                with client:
                    try:
                        handle_client(client, args.output)
                    except EOFError:
                        print('Phone disconnected; no incomplete frame committed.', flush=True)
                    except Exception as error:
                        print(f'Rejected/connection error: {error}', flush=True)
                        try:
                            client.sendall(b'\x15')
                        except OSError:
                            pass
        except KeyboardInterrupt:
            print('\nReceiver stopped.')


if __name__ == '__main__':
    main()
