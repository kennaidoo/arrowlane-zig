"""Small ctypes binding for the arrowlane-zig C ABI.

The caller supplies the shared library path. Buffer and reason fields use
``c_void_p`` so ctypes does not copy or reinterpret the pointer.
"""

from __future__ import annotations

import ctypes
from ctypes import POINTER, Structure, c_bool, c_char_p, c_double, c_int, c_size_t, c_uint64, c_ubyte, c_void_p


class AlBuffer(Structure):
    _fields_ = [
        ("data", c_void_p),
        ("len", c_size_t),
        ("cap", c_size_t),
    ]


class AlDecision(Structure):
    _fields_ = [
        ("lane_id", c_ubyte),
        ("predicted_ms", c_double),
        ("predicted_bytes", c_uint64),
        ("reason", c_void_p),
    ]


class Library:
    def __init__(self, path: str) -> None:
        self.lib = ctypes.CDLL(path)
        self.lib.al_version.restype = c_char_p
        self.lib.al_version.argtypes = []
        self.lib.al_select.restype = c_int
        self.lib.al_select.argtypes = [
            c_uint64,
            c_uint64,
            c_ubyte,
            c_ubyte,
            c_bool,
            POINTER(AlDecision),
        ]
        self.lib.al_inspect.restype = AlBuffer
        self.lib.al_inspect.argtypes = [c_void_p, c_size_t]
        self.lib.al_repack.restype = AlBuffer
        self.lib.al_repack.argtypes = [c_void_p, c_size_t, c_ubyte]
        self.lib.al_free.argtypes = [AlBuffer]
        self.lib.al_free.restype = None
        self.lib.al_free_reason.argtypes = [c_void_p]
        self.lib.al_free_reason.restype = None

    def version(self) -> str:
        return self.lib.al_version().decode("ascii")

    def select(self, rows: int, arrow_bytes: int, topology: int = 1, policy: int = 0, shm_ready: bool = False) -> AlDecision:
        decision = AlDecision()
        code = self.lib.al_select(rows, arrow_bytes, topology, policy, shm_ready, ctypes.byref(decision))
        if code != 0:
            raise RuntimeError(f"al_select returned {code}")
        return decision

    def inspect(self, wire: bytes) -> bytes:
        source = ctypes.create_string_buffer(wire)
        buffer = self.lib.al_inspect(source, len(wire))
        try:
            if not buffer.data:
                raise RuntimeError("al_inspect returned an empty buffer")
            return ctypes.string_at(buffer.data, buffer.len)
        finally:
            self.lib.al_free(buffer)

    def repack(self, wire: bytes, lane_id: int) -> bytes:
        source = ctypes.create_string_buffer(wire)
        buffer = self.lib.al_repack(source, len(wire), lane_id)
        try:
            if not buffer.data:
                raise RuntimeError("al_repack returned an empty buffer")
            return ctypes.string_at(buffer.data, buffer.len)
        finally:
            self.lib.al_free(buffer)

    def free_reason(self, reason: int) -> None:
        self.lib.al_free_reason(reason)

    def free(self, buffer: AlBuffer) -> None:
        self.lib.al_free(buffer)
