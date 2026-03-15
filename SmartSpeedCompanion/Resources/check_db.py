import sqlite3
import sys

db_path = r"c:\Users\madhu\SmartSpeedCompanion iOS CarPlay\SmartSpeedCompanion\Resources\HPMS_2024_Data_-2111065798425599378.geodatabase"

try:
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    
    cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '%spindex%';")
    tables = [t[0] for t in cursor.fetchall()]
    print("INDEX TABLES:", tables)
        
    for t in tables:
        print(f"\nCOLUMNS FOR {t}:")
        cursor.execute(f"PRAGMA table_info('{t}');")
        for col in cursor.fetchall():
            print(f"  {col[1]} ({col[2]})")
            
    conn.close()
except Exception as e:
    print(f"ERROR: {e}")
