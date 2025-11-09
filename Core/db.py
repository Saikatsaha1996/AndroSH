import sqlite3
import json
import threading
from datetime import datetime
from typing import Any, Optional, Union, Dict, List, Tuple
from Core import name


class DB:
	_instance = None
	_lock = threading.Lock()

	def __new__(cls, db_path: str = f"Assets/{name}.db"):
		with cls._lock:
			if cls._instance is None:
				cls._instance = super(DB, cls).__new__(cls)
				cls._instance._initialized = False
			return cls._instance

	def __init__(self, db_path: str = f"Assets/{name}.db"):
		if self._initialized:
			return

		self.db_path = db_path
		self.conn = None
		self._initialized = True
		self._initialize_database()

	def _initialize_database(self) -> None:
		"""Initialize the database tables if they don't exist."""
		conn = None
		try:
			conn = sqlite3.connect(self.db_path)
			cursor = conn.cursor()

			# Create main table
			cursor.execute("""
                           CREATE TABLE IF NOT EXISTS data
                           (
                               id
                               INTEGER
                               PRIMARY
                               KEY
                               AUTOINCREMENT,
                               key
                               TEXT
                               NOT
                               NULL
                               UNIQUE,
                               value
                               TEXT,
                               created_at
                               TIMESTAMP
                               DEFAULT
                               CURRENT_TIMESTAMP,
                               updated_at
                               TIMESTAMP
                               DEFAULT
                               CURRENT_TIMESTAMP
                           )
			               """)

			# Create subdata table for nested data
			cursor.execute("""
                           CREATE TABLE IF NOT EXISTS subdata
                           (
                               id
                               INTEGER
                               PRIMARY
                               KEY
                               AUTOINCREMENT,
                               parent_key
                               TEXT
                               NOT
                               NULL,
                               subkey
                               TEXT
                               NOT
                               NULL,
                               subvalue
                               TEXT,
                               created_at
                               TIMESTAMP
                               DEFAULT
                               CURRENT_TIMESTAMP,
                               updated_at
                               TIMESTAMP
                               DEFAULT
                               CURRENT_TIMESTAMP,
                               FOREIGN
                               KEY
                           (
                               parent_key
                           ) REFERENCES data
                           (
                               key
                           ) ON DELETE CASCADE,
                               UNIQUE
                           (
                               parent_key,
                               subkey
                           )
                               )
			               """)

			# Enable foreign keys
			cursor.execute("PRAGMA foreign_keys = ON")

			conn.commit()

		except sqlite3.Error as e:
			print(f"Database initialization error: {e}")
		finally:
			if conn:
				conn.close()

	def _get_connection(self):
		"""Get a new connection (thread-safe)."""
		conn = sqlite3.connect(self.db_path)
		conn.execute("PRAGMA foreign_keys = ON")
		return conn

	def _execute_operation(self, operation, *args):
		"""Execute a database operation safely."""
		conn = None
		try:
			conn = self._get_connection()
			cursor = conn.cursor()
			result = operation(cursor, *args)
			conn.commit()
			return result
		except sqlite3.Error as e:
			print(f"Database operation error: {e}")
			if conn:
				conn.rollback()
			return None
		finally:
			if conn:
				conn.close()

	def _serialize_value(self, value: Any) -> str:
		return json.dumps(value)

	def _deserialize_value(self, value_str: str) -> Any:
		if value_str is None:
			return None
		return json.loads(value_str)

	def check(self) -> Optional[Any]:
		"""Check if project setup is complete."""

		def op(cursor):
			cursor.execute("SELECT value FROM data WHERE key = 'done'")
			result = cursor.fetchone()
			if result:
				done_value = self._deserialize_value(result[0])
				if done_value.get("status"):
					return done_value.get("name")
			return False

		return self._execute_operation(op)

	def setup(self, done: bool = True, name: str = name) -> bool:
		"""Mark project setup as complete or incomplete."""

		def op(cursor):
			serialized_done = self._serialize_value({
				"status": done,
				"name": name
			})
			cursor.execute(
				"INSERT OR REPLACE INTO data (key, value, updated_at) VALUES (?, ?, ?)",
				('done', serialized_done, datetime.now().isoformat())
			)
			return True

		return self._execute_operation(op) or False

	def add(self, key: str, value: Any) -> bool:
		"""Add a new key-value pair to the database."""

		def op(cursor):
			serialized_value = self._serialize_value(value)
			cursor.execute(
				"INSERT OR REPLACE INTO data (key, value, updated_at) VALUES (?, ?, ?)",
				(key, serialized_value, datetime.now().isoformat())
			)
			return True

		return self._execute_operation(op) or False

	def subadd(self, key: str, subkey: str, subvalue: Any) -> bool:
		"""Add a subkey-value pair to an existing key."""

		def op(cursor):
			# Ensure parent key exists
			cursor.execute("SELECT 1 FROM data WHERE key = ?", (key,))
			if not cursor.fetchone():
				serialized_empty = self._serialize_value({})
				cursor.execute(
					"INSERT INTO data (key, value, updated_at) VALUES (?, ?, ?)",
					(key, serialized_empty, datetime.now().isoformat())
				)

			serialized_subvalue = self._serialize_value(subvalue)
			cursor.execute(
				"""INSERT OR REPLACE INTO subdata 
				   (parent_key, subkey, subvalue, updated_at) 
				   VALUES (?, ?, ?, ?)""",
				(key, subkey, serialized_subvalue, datetime.now().isoformat())
			)
			return True

		return self._execute_operation(op) or False

	def get(self, key: str) -> Optional[Any]:
		"""Get value for a specific key."""

		def op(cursor):
			cursor.execute("SELECT value FROM data WHERE key = ?", (key,))
			result = cursor.fetchone()
			if result:
				return self._deserialize_value(result[0])
			return None

		return self._execute_operation(op)

	def subget(self, key: str, subkey: str) -> Optional[Any]:
		"""Get subvalue for a specific key and subkey."""

		def op(cursor):
			cursor.execute(
				"SELECT subvalue FROM subdata WHERE parent_key = ? AND subkey = ?",
				(key, subkey)
			)
			result = cursor.fetchone()
			if result:
				return self._deserialize_value(result[0])
			return None

		return self._execute_operation(op)

	def get_all_subdata(self, key: str) -> Optional[Dict[str, Any]]:
		"""Get all subdata for a specific key."""

		def op(cursor):
			cursor.execute(
				"SELECT subkey, subvalue FROM subdata WHERE parent_key = ?",
				(key,)
			)
			results = cursor.fetchall()
			if results:
				return {subkey: self._deserialize_value(subvalue) for subkey, subvalue in results}
			return {}

		return self._execute_operation(op)

	def update(self, update_data: Dict[str, Any]) -> bool:
		"""Update multiple key-value pairs."""

		def op(cursor):
			for key, value in update_data.items():
				if isinstance(value, dict):
					for subkey, subvalue in value.items():
						# Ensure parent key exists
						cursor.execute("SELECT 1 FROM data WHERE key = ?", (key,))
						if not cursor.fetchone():
							serialized_empty = self._serialize_value({})
							cursor.execute(
								"INSERT INTO data (key, value, updated_at) VALUES (?, ?, ?)",
								(key, serialized_empty, datetime.now().isoformat())
							)

						serialized_subvalue = self._serialize_value(subvalue)
						cursor.execute(
							"""INSERT OR REPLACE INTO subdata 
							   (parent_key, subkey, subvalue, updated_at) 
							   VALUES (?, ?, ?, ?)""",
							(key, subkey, serialized_subvalue, datetime.now().isoformat())
						)
				else:
					serialized_value = self._serialize_value(value)
					cursor.execute(
						"INSERT OR REPLACE INTO data (key, value, updated_at) VALUES (?, ?, ?)",
						(key, serialized_value, datetime.now().isoformat())
					)
			return True

		return self._execute_operation(op) or False

	def fetchall(self) -> Dict[str, Any]:
		"""Fetch all data from the database."""

		def op(cursor):
			# Get all main data
			cursor.execute("SELECT key, value FROM data")
			main_data = {key: self._deserialize_value(value) for key, value in cursor.fetchall()}

			# Get all subdata
			cursor.execute("SELECT parent_key, subkey, subvalue FROM subdata")
			subdata_results = cursor.fetchall()

			for parent_key, subkey, subvalue in subdata_results:
				if parent_key in main_data:
					if isinstance(main_data[parent_key], dict):
						main_data[parent_key][subkey] = self._deserialize_value(subvalue)
					else:
						main_data[parent_key] = {**main_data[parent_key], subkey: self._deserialize_value(subvalue)}
				else:
					main_data[parent_key] = {subkey: self._deserialize_value(subvalue)}

			return main_data

		return self._execute_operation(op) or {}

	def remove(self, key: str, subkey: Optional[str] = None) -> bool:
		"""Remove a key or subkey from the database."""

		def op(cursor):
			if subkey:
				cursor.execute(
					"DELETE FROM subdata WHERE parent_key = ? AND subkey = ?",
					(key, subkey)
				)
			else:
				cursor.execute("DELETE FROM subdata WHERE parent_key = ?", (key,))
				cursor.execute("DELETE FROM data WHERE key = ?", (key,))
			return True

		return self._execute_operation(op) or False

	def exists(self, key: str, subkey: Optional[str] = None) -> bool:
		"""Check if a key or subkey exists."""

		def op(cursor):
			if subkey:
				cursor.execute(
					"SELECT 1 FROM subdata WHERE parent_key = ? AND subkey = ?",
					(key, subkey)
				)
			else:
				cursor.execute("SELECT 1 FROM data WHERE key = ?", (key,))
			return cursor.fetchone() is not None

		return self._execute_operation(op) or False

	def count(self) -> Tuple[int, int]:
		"""Count total keys and subkeys."""

		def op(cursor):
			cursor.execute("SELECT COUNT(*) FROM data")
			main_count = cursor.fetchone()[0]

			cursor.execute("SELECT COUNT(*) FROM subdata")
			sub_count = cursor.fetchone()[0]

			return main_count, sub_count

		return self._execute_operation(op) or (0, 0)