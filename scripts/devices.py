import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    data = json.load(source)
for device in data["result"]["devices"]:
    properties = device.get("properties", {})
    hardware = properties.get("hardware", device.get("hardwareProperties", {}))
    connection = properties.get("connection", device.get("connectionProperties", {}))
    state = properties.get("state", device.get("deviceProperties", {}))
    if hardware.get("reality") != "physical" or hardware.get("deviceType") not in ("iPhone", "iPad"):
        continue
    if connection.get("state", connection.get("tunnelState")) != "connected":
        continue
    print("\t".join((state.get("name", "Unknown"), device["identifier"], hardware.get("udid", ""))))
