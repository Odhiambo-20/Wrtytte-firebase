# wrytte

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

# Wrytte App — OpenIM Server Setup & Operations Guide

## Overview

The Wrytte app uses **OpenIM** for real-time chat and messaging. The server runs on a Google Cloud VM at `34.63.32.143` and is fully orchestrated with Docker Compose. This guide covers everything needed to start, stop, monitor, and troubleshoot the server.

---

## Server Details

| Property | Value |
|---|---|
| **Server IP** | `34.63.32.143` |
| **SSH User** | `odhiambov110` |
| **Compose Directory** | `/home/odhiambov110/openim-docker` |
| **Chat API Port** | `10008` |
| **IM Server Port** | `10002` |
| **WebSocket Port** | `10001` |
| **Admin API Port** | `10009` |
| **MinIO (File Storage)** | `10005` |

---

## Prerequisites

- SSH access to the server
- Docker and Docker Compose installed on the server (already set up)
- The `openim-docker` repo cloned at `/home/odhiambov110/openim-docker`

---

## 1. SSH Into the Server

```bash
ssh odhiambov110@34.63.32.143
```

---

## 2. Starting the Server

### First Time / After a Full Stop

```bash
cd /home/odhiambov110/openim-docker
docker compose up -d
```

### If You Get "Container Name Already in Use" Errors

This happens when old containers from a previous session are still registered. Run:

```bash
# Remove all OpenIM-related containers at once
docker ps -a --format '{{.Names}}' | grep -E 'openim|kafka|etcd|mongodb|redis|minio|mongo' | xargs docker rm -f

# Then start fresh
docker compose up -d
```

If `minio` or `mongo` are missed by the grep, remove them individually:

```bash
docker rm -f minio mongo
docker compose up -d
```

### Verify All Containers Are Running

```bash
docker compose ps
```

Expected output — all 9 containers should show **Up** or **healthy**:

```
openim-chat          Up (healthy)   0.0.0.0:10008-10009->10008-10009/tcp
openim-server        Up (healthy)   0.0.0.0:10001-10002->10001-10002/tcp
minio                Up             0.0.0.0:10005->9000/tcp
mongo                Up             27017/tcp
openim-web-front     Up             0.0.0.0:11001->80/tcp
openim-admin-front   Up             0.0.0.0:11002->80/tcp
redis                Up             6379/tcp
kafka                Up             9092/tcp
etcd                 Up             0.0.0.0:12379->2379/tcp
```

---

## 3. Stopping the Server

### Stop All Containers (Keep Data)

```bash
cd /home/odhiambov110/openim-docker
docker compose down
```

### Stop a Single Service

```bash
docker compose stop openim-chat
docker compose stop openim-server
```

### Stop and Remove Everything (Nuclear Option — Data is Preserved in Volumes)

```bash
docker compose down --remove-orphans
```

---

## 4. Restarting Services

### Restart a Single Container

```bash
cd /home/odhiambov110/openim-docker
docker compose restart openim-chat
docker compose restart openim-server
```

### Restart Everything

```bash
docker compose restart
```

---

## 5. Verifying the Server is Working

### Test the IM Server (Port 10002)

```bash
curl -s -X POST http://localhost:10002/auth/get_admin_token \
  -H "Content-Type: application/json" \
  -H "operationID: test123" \
  -d '{"secret":"openIM123","userID":"imAdmin"}'
```

✅ Expected: `{"errCode":0,...,"data":{"token":"eyJ..."}}`

### Test the Chat Server (Port 10008)

```bash
curl -s -X POST http://localhost:10008/account/login \
  -H "Content-Type: application/json" \
  -H "operationID: test123" \
  -d '{"areaCode":"+254","phoneNumber":"748630243","verifyCode":"666666","platform":2}'
```

✅ Expected: `{"errCode":0,...,"data":{"imToken":"eyJ...","chatToken":"eyJ...","userID":"..."}}`

### Test Chat-to-IM Connectivity (From Inside Chat Container)

```bash
docker exec openim-chat wget -qO- \
  --post-data='{"secret":"openIM123","userID":"imAdmin"}' \
  --header='Content-Type: application/json' \
  --header='operationID: test123' \
  http://openim-server:10002/auth/get_admin_token
```

✅ Expected: `{"errCode":0,...}`

---

## 6. API Reference

### Register a New User

```bash
curl -s -X POST http://localhost:10008/account/register \
  -H "Content-Type: application/json" \
  -H "operationID: test123" \
  -d '{
    "verifyCode": "666666",
    "platform": 2,
    "autoLogin": true,
    "user": {
      "nickname": "TestUser",
      "faceURL": "",
      "areaCode": "+254",
      "phoneNumber": "748630243"
    }
  }'
```

### Login an Existing User

```bash
curl -s -X POST http://localhost:10008/account/login \
  -H "Content-Type: application/json" \
  -H "operationID: test123" \
  -d '{
    "areaCode": "+254",
    "phoneNumber": "748630243",
    "verifyCode": "666666",
    "platform": 2
  }'
```

> **Note:** `verifyCode` is always `666666`. This is the server's built-in super-code that bypasses SMS verification. To enable real SMS, configure an SMS provider in `/openim-chat/config/chat-rpc-chat.yml` inside the container.

### Important API Notes

| Field | Location | Note |
|---|---|---|
| `areaCode` | Inside `user` object for register | e.g. `"+254"` |
| `phoneNumber` | Inside `user` object for register | Local number only, e.g. `"748630243"` |
| `areaCode` | Top-level for login | e.g. `"+254"` |
| `verifyCode` | Always `"666666"` | Super-code, no SMS needed |
| `operationID` header | Required on all requests | Any unique string |

---

## 7. Viewing Logs

### View Live Logs for All Services

```bash
cd /home/odhiambov110/openim-docker
docker compose logs -f
```

### View Logs for a Specific Service

```bash
docker compose logs -f openim-chat
docker compose logs -f openim-server
```

### View Last 100 Lines

```bash
docker logs openim-chat --tail 100
docker logs openim-server --tail 100
```

### Filter for Errors Only

```bash
docker logs openim-chat 2>&1 | grep -E "ERROR|panic|fatal" | grep -v "rpc"
```

---

## 8. Configuration Files

All config lives **inside** the `openim-chat` container at `/openim-chat/config/`:

| File | Purpose |
|---|---|
| `chat-api-chat.yml` | Chat API port (10008) |
| `chat-rpc-chat.yml` | SMS provider config, super-code (`666666`) |
| `share.yml` | OpenIM server URL and secret |
| `discovery.yml` | etcd service discovery |
| `redis.yml` | Redis connection |
| `mongodb.yml` | MongoDB connection |

### Read a Config File

```bash
docker exec openim-chat cat /openim-chat/config/share.yml
docker exec openim-chat cat /openim-chat/config/chat-rpc-chat.yml
```

### Environment Variables (Set in docker-compose.yaml)

| Variable | Value | Purpose |
|---|---|---|
| `CHATENV_SHARE_OPENIM_APIURL` | `http://openim-server:10002` | IM server URL |
| `CHATENV_SHARE_OPENIM_SECRET` | `openIM123` | Shared secret |
| `CHATENV_DISCOVERY_ETCD_ADDRESS` | `etcd:2379` | Service discovery |

---

## 9. Enabling Real SMS (Production)

To replace the `666666` super-code with real SMS, edit the chat-rpc config:

```bash
# Copy config out of container
docker cp openim-chat:/openim-chat/config/chat-rpc-chat.yml ./chat-rpc-chat.yml

# Edit the file — fill in your SMS provider details
nano chat-rpc-chat.yml
```

The relevant section:

```yaml
verifyCode:
  superCode: "666666"   # ← Remove or change this in production
  phone:
    use: "ali"          # ← Set to "ali" for Alibaba Cloud SMS
    ali:
      endpoint: ""
      accessKeyId: ""
      accessKeySecret: ""
      signName: ""
      verificationCodeTemplateCode: ""
```

After editing, copy it back and restart:

```bash
docker cp ./chat-rpc-chat.yml openim-chat:/openim-chat/config/chat-rpc-chat.yml
docker compose restart openim-chat
```

---

## 10. Troubleshooting

### Container Won't Start — Name Already in Use

```bash
docker ps -a --format '{{.Names}}' | grep -E 'openim|kafka|etcd|mongo|redis|minio' | xargs docker rm -f
docker compose up -d
```

### Chat API Returns 404 on All Routes

The chat-api may not have fully initialized. Restart it:

```bash
docker compose restart openim-chat
sleep 15
curl -s http://localhost:10008/account/login -X POST \
  -H "Content-Type: application/json" \
  -H "operationID: test" \
  -d '{}'
```

If you get `{"errCode":1001}` instead of `404 page not found`, the routes are registered and the server is healthy.

### Chat Server Can't Reach IM Server

```bash
docker exec openim-chat wget -qO- http://openim-server:10002/healthz
```

If this returns `404 Not Found` (not a connection error), the network is fine. If it times out, check that `openim-server` is running:

```bash
docker ps | grep openim-server
```

### Check Which Ports Are Listening

```bash
docker exec openim-chat netstat -tlnp
```

Expected:
```
tcp   :::10008   LISTEN   chat-api
tcp   :::10009   LISTEN   admin-api
tcp   :::30300   LISTEN   chat-rpc
tcp   :::30200   LISTEN   admin-rpc
```

### Full Reset (Keeps All Data)

```bash
cd /home/odhiambov110/openim-docker
docker compose down --remove-orphans
docker ps -a --format '{{.Names}}' | grep -E 'openim|kafka|etcd|mongo|redis|minio' | xargs docker rm -f 2>/dev/null
docker compose up -d
```

---

## 11. Flutter App Configuration

The Flutter app connects to these endpoints defined in `lib/services/auth/auth_service.dart` and `lib/services/auth/openim_chat_service.dart`:

| Endpoint | URL |
|---|---|
| IM Server API | `http://34.63.32.143:10002` |
| Chat Server API | `http://34.63.32.143:10008` |
| WebSocket | `ws://34.63.32.143:10001` |

### OTP Code for Testing

During development, always use `666666` as the OTP. The UI accepts any 6-digit input but the server only validates `666666`.

---

## 12. Quick Reference Cheatsheet

```bash
# SSH in
ssh odhiambov110@34.63.32.143

# Go to compose directory
cd /home/odhiambov110/openim-docker

# Start all services
docker compose up -d

# Check status
docker compose ps

# View chat logs live
docker compose logs -f openim-chat

# Restart chat service
docker compose restart openim-chat

# Test chat server health
curl -s -X POST http://localhost:10008/account/login \
  -H "Content-Type: application/json" \
  -H "operationID: test" \
  -d '{"areaCode":"+254","phoneNumber":"748630243","verifyCode":"666666","platform":2}'

# Stop everything
docker compose down



---------------------------------------------------

Where are these chats coming from cause I cleared cache and the firebase but am still seeing them

These chats are coming from your **OpenIM server**, not Firebase.

You have `flutter_openim_sdk` in your `pubspec.yaml` and your own OpenIM server running at:
```
http://34.63.32.143:10008
```

OpenIM stores chats on **its own server and local SDK cache**, completely separate from Firebase. That's why clearing Firebase didn't remove them.

---

## To Clear Them

**Option 1 — Clear OpenIM local SDK cache** (on device):
```dart
OpenIM.iMManager.logout();
```

**Option 2 — Clear from the server side**, go to your OpenIM docker:
```bash
cd ~/Pictures/wrytte/openim-docker-fresh
docker compose down
docker volume prune
docker compose up -d
```
⚠️ This deletes **all** messages for all users.

**Option 3 — Uninstall the app** on the device, which wipes the local OpenIM SDK storage.

---

## Summary

| Storage | Cleared by Firebase clear? |
|---|---|
| Firebase Firestore | ✅ Yes |
| OpenIM server | ❌ No |
| OpenIM local SDK | ❌ No |



```


