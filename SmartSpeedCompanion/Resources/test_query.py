import sqlite3
db_path = r"c:\Users\madhu\SmartSpeedCompanion iOS CarPlay\SmartSpeedCompanion\Resources\HPMS_2024_Data_-2111065798425599378.geodatabase"
conn = sqlite3.connect(db_path)
cursor = conn.cursor()

# Area near Queen Creek: 33.24, -111.64
lat, lon = 33.24, -111.64
searchBuffer = 0.05

sql = """
    SELECT a.SpeedLimit, b.minx, b.maxx, b.miny, b.maxy
    FROM SpeedLimit_2024 a
    JOIN st_spindex__SpeedLimit_2024_SHAPE b ON a.OBJECTID = b.pkid
    WHERE ? <= b.maxx AND ? >= b.minx
      AND ? <= b.maxy AND ? >= b.miny
    LIMIT 10
"""
cursor.execute(sql, (lon - searchBuffer, lon + searchBuffer, lat - searchBuffer, lat + searchBuffer))
rows = cursor.fetchall()
print(f"Found {len(rows)} rows near {lat}, {lon}")
for r in rows:
    print(r)
conn.close()
