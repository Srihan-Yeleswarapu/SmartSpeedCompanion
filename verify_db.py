import sqlite3
import os

db_path = r"c:\Users\madhu\SmartSpeedCompanion iOS CarPlay\SmartSpeedCompanion\Resources\ArizonaSpeedLimits.sqlite"

if not os.path.exists(db_path):
    print(f"Database not found at {db_path}")
    exit(1)

conn = sqlite3.connect(db_path)
cursor = conn.cursor()

cursor.execute("SELECT COUNT(*) FROM SpeedLimit_2024;")
count = cursor.fetchone()[0]
print(f"Count: {count}")

cursor.execute("SELECT SpeedLimit, OBJECTID FROM SpeedLimit_2024 LIMIT 5;")
rows = cursor.fetchall()
for row in rows:
    print(f"Limit: {row[0]}, ID: {row[1]}")

conn.close()
