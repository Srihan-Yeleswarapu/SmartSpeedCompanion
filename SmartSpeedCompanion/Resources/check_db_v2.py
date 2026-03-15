import sqlite3
import os

db_path = r"c:\Users\madhu\SmartSpeedCompanion iOS CarPlay\SmartSpeedCompanion\Resources\HPMS_2024_Data_-2111065798425599378.geodatabase"

conn = sqlite3.connect(db_path)
cursor = conn.cursor()

def get_tables():
    cursor.execute("SELECT name FROM sqlite_master WHERE type='table';")
    return [t[0] for t in cursor.fetchall()]

def get_schema(table_name):
    print(f"\n--- {table_name} ---")
    cursor.execute(f"PRAGMA table_info({table_name});")
    for col in cursor.fetchall():
        print(f"COL: {col[1]} ({col[2]})")

tables = get_tables()
print("TABLES FOUND:", ", ".join(tables))

for t in ["SpeedLimit_2024", "st_spindex__SpeedLimit_2024_SHAPE"]:
    if t in tables:
        get_schema(t)
    else:
        print(f"TABLE {t} NOT FOUND")

conn.close()
