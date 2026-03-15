import sqlite3
db_path = r"c:\Users\madhu\SmartSpeedCompanion iOS CarPlay\SmartSpeedCompanion\Resources\HPMS_2024_Data_-2111065798425599378.geodatabase"
conn = sqlite3.connect(db_path)
cursor = conn.cursor()
cursor.execute("SELECT rowid, OBJECTID FROM SpeedLimit_2024 LIMIT 5;")
for row in cursor.fetchall():
    print(row)
conn.close()
