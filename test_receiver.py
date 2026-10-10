"""Run from Server: python -m unittest -v test_receiver.py"""
import copy
import io
import json
from pathlib import Path
import socket
import struct
import tempfile
import threading
import unittest
import uuid

from PIL import Image
import ios_driver as receiver


def sample():
    meta = dict(schema_version=2, recording_id=str(uuid.uuid4()), frame_id=0,
                timestamp_seconds=100.0, elapsed_seconds=0.0,
                rgb_file='rgb.jpg', depth_file='depth.bin', rgb_width=4, rgb_height=4,
                depth_width=2, depth_height=2, depth_dtype='float32', depth_byte_order='little',
                depth_units='meters', matrix_serialization='rows',
                camera_to_world_4x4=[[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]],
                camera_intrinsics_3x3=[[3,0,2],[0,3,2],[0,0,1]],
                intrinsics_reference_width=4, intrinsics_reference_height=4,
                position_meters={'x':0,'y':0,'z':0}, rotation_quaternion_xyzw=[0,0,0,1],
                tracking_state='normal', confidence_file='confidence.bin',
                confidence_dtype='uint8', confidence_width=2, confidence_height=2)
    image = io.BytesIO()
    Image.new('RGB', (4,4), (80,150,200)).save(image, format='JPEG')
    return meta, image.getvalue(), struct.pack('<4f', 1, 2, 3, 4), bytes([2,2,1,0])


def packet(meta, rgb, depth, confidence):
    blocks = [json.dumps(meta).encode(), rgb, depth, confidence]
    return receiver.HEADER.pack(receiver.MAGIC, *map(len, blocks)) + b''.join(blocks)


class ReceiverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.data = sample()

    def tearDown(self):
        self.temp.cleanup()

    def connect(self):
        # Real TCP, with an ephemeral loopback port.
        listener = socket.socket()
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        client = socket.create_connection(listener.getsockname())
        client.settimeout(3)
        server, _ = listener.accept()
        listener.close()
        errors = []
        def run():
            with server:
                try:
                    receiver.handle_client(server, self.root)
                except Exception as e:
                    errors.append(e)
        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        self.assertEqual(receiver.receive_exact(client, 4), receiver.MAGIC)
        self.addCleanup(client.close)
        return client, thread, errors

    def test_fragmented_two_frames_and_ack_after_save(self):
        client, thread, errors = self.connect()
        meta, rgb, depth, confidence = self.data
        for fid in (0,1):
            meta['frame_id'] = fid
            meta['timestamp_seconds'] = 100+fid
            payload = packet(meta,rgb,depth,confidence)
            for i in range(0,len(payload),7):
                client.sendall(payload[i:i+7])
            self.assertEqual(receiver.receive_exact(client,1),b'\x06')
            folder = self.root / meta['recording_id'] / f'frame_{fid:06d}'
            self.assertEqual((folder/'depth.bin').read_bytes(),depth)
            self.assertEqual((folder/'rgb.jpg').read_bytes(),rgb)
            self.assertEqual(json.loads((folder/'metadata.json').read_text())['frame_id'],fid)
        client.close()
        thread.join(3)
        self.assertFalse(thread.is_alive())
        self.assertIsInstance(errors[0],EOFError)

    def test_disconnect_halfway_commits_nothing(self):
        client, thread, errors = self.connect()
        payload = packet(*self.data)
        client.sendall(payload[:len(payload)//2])
        client.close()
        thread.join(3)
        self.assertFalse(list(self.root.rglob('metadata.json')))
        self.assertIsInstance(errors[0],EOFError)

    def test_oversize_header_rejected_without_payload(self):
        client, thread, errors = self.connect()
        client.sendall(receiver.HEADER.pack(receiver.MAGIC, 99999999,1,1,0))
        thread.join(3)
        self.assertFalse(thread.is_alive())
        self.assertIsInstance(errors[0],ValueError)

    def test_bad_depth_rejected(self):
        meta,rgb,depth,confidence=self.data
        with self.assertRaises(ValueError):
            receiver.save_frame(self.root,meta,rgb,depth[:-1],confidence)
        self.assertFalse(list(self.root.iterdir()))

    def test_bad_pose_and_path_rejected(self):
        for mutate in (lambda m: m.update(recording_id='../escape'),
                       lambda m: m['camera_to_world_4x4'][0].__setitem__(0,2),
                       lambda m: m.update(timestamp_seconds=float('nan'))):
            meta,rgb,depth,confidence=copy.deepcopy(self.data)
            mutate(meta)
            with self.assertRaises(ValueError):
                receiver.save_frame(self.root,meta,rgb,depth,confidence)

    def test_wrong_jpeg_dimensions_rejected(self):
        meta,rgb,depth,confidence=self.data
        meta['rgb_width']=8
        meta['intrinsics_reference_width']=8
        with self.assertRaises(ValueError):
            receiver.save_frame(self.root,meta,rgb,depth,confidence)

    def test_duplicate_preserves_original(self):
        folder=receiver.save_frame(self.root,*self.data)
        with self.assertRaises(ValueError):
            receiver.save_frame(self.root,*self.data)
        self.assertEqual((folder/'depth.bin').read_bytes(),self.data[2])

    def test_optional_confidence(self):
        meta,rgb,depth,_=self.data
        for key in list(meta):
            if key.startswith('confidence_'): del meta[key]
        folder=receiver.save_frame(self.root,meta,rgb,depth,b'')
        self.assertFalse((folder/'confidence.bin').exists())


if __name__ == '__main__':
    unittest.main()
