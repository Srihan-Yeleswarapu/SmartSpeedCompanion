import sqlite3

db_path = "Resources/HPMS_2024_Data_-2111065798425599378.geodatabase"
try:
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    
    # Simulate a user location around an Arizona road:
    # Let's find a valid road segment bounding box first:
    row = cur.execute("SELECT pkid, minx, maxx, miny, maxy FROM st_spindex__SpeedLimit_2024_SHAPE LIMIT 1").fetchone()
    print("Found segment BBox:", row)
    
    # Simulate user in the middle of this bbox
    test_lon = (row[1] + row[2]) / 2.0
    test_lat = (row[3] + row[4]) / 2.0
    
    print(f"\nUser at {test_lat}, {test_lon}")
    
    res = cur.execute('''
        SELECT a.SpeedLimit, b.minx, b.maxx, b.miny, b.maxy 
        FROM SpeedLimit_2024 a
        JOIN st_spindex__SpeedLimit_2024_SHAPE b ON a.OBJECTID = b.pkid
        WHERE ? BETWEEN b.minx AND b.maxx
          AND ? BETWEEN b.miny AND b.maxy
    ''', (test_lon, test_lat)).fetchall()
    
    print("Matches for user point:", res)
    
except Exception as e:
    print(f"Error: {e}")
