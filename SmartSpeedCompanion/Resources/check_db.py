import sqlite3
import os

db_path = r"c:\Users\madhu\SmartSpeedCompanion iOS CarPlay\SmartSpeedCompanion\Resources\HPMS_2024_Data_-2111065798425599378.geodatabase"

if not os.path.exists(db_path):
    print(f"Database not found at {db_path}")
    exit(1)

conn = sqlite3.connect(db_path)
cursor = conn.cursor()

print("--- TABLES ---")
cursor.execute("SELECT name FROM sqlite_master WHERE type='table';")
tables = cursor.fetchall()
for table in tables:
    print(table[0])

print("\n--- SCHEMA SpeedLimit_2024 ---")
try:
    cursor.execute("PRAGMA table_info(SpeedLimit_2024);")
    columns = cursor.fetchall()
    for col in columns:
        print(f"{col[1]} ({col[2]})")
except Exception as e:
    print(f"Error reading SpeedLimit_2024: {e}")

print("\n--- SCHEMA st_spindex__SpeedLimit_2024_SHAPE ---")
try:
    cursor.execute("PRAGMA table_info(st_spindex__SpeedLimit_2024_SHAPE);")
    columns = cursor.fetchall()
    for col in columns:
        print(f"{col[1]} ({col[2]})")
except Exception as e:
    print(f"Error reading index table: {e}")

conn.close()
