"""
Mock HTTP server for testing dynamic-dns-netcup-api.

Simulates:
  - IP address lookup services (IPv4 and IPv6)
  - netcup CCP DNS API (login, logout, infoDnsZone, infoDnsRecords,
    updateDnsRecords, updateDnsZone)

GET endpoints (IP lookup):
  /health          - Returns 200 (used by test.sh to wait for server readiness)
  /reset           - Resets all server-side state (call between stateful tests)
  /ipv4            - Returns a plain-text IPv4 address (203.0.113.42)
  /ipv6            - Returns a plain-text IPv6 address (2001:db8::42)
  /ipv4-garbage    - Returns invalid text (for testing fallback behavior)

POST endpoints (netcup API variants):
  /api                 - Normal happy path: records match current IP, TTL=300
  /api-login-fail      - Login always returns error (wrong credentials)
  /api-ip-changed      - DNS records have a stale IP (triggers update)
  /api-no-records      - No DNS records for the subdomain (triggers creation)
  /api-dup-records     - Duplicate A records for same host (triggers error)
  /api-high-ttl        - infoDnsZone returns TTL=3600 (triggers TTL change)
  /api-session-expire  - First non-login action returns 4001 (triggers re-login)
  /api-session-refresh - First 4001 forces a new session ID that later calls must reuse
"""

import json
import socket
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler

# ---------------------------------------------------------------------------
# Fake data used across API responses
# ---------------------------------------------------------------------------
FAKE_IPV4 = "203.0.113.42"
FAKE_IPV6 = "2001:db8::42"
FAKE_SESSION_ID = "test-session-id-abc123"


class MockHandler(BaseHTTPRequestHandler):
    """Handles GET requests for IP lookups and POST requests for the netcup API."""

    # ---- Shared state for stateful test scenarios ----
    # /api-session-expire: first non-login action returns 4001, then resets.
    session_expire_triggered = False
    session_refresh_triggered = False
    session_refresh_login_count = 0
    session_refresh_active_session_id = FAKE_SESSION_ID

    def log_message(self, format, *args):
        """Suppress default request logging to keep test output clean."""
        pass

    # ------------------------------------------------------------------
    # GET handler
    # ------------------------------------------------------------------
    def do_GET(self):
        if self.path == "/health":
            self._respond(200, "OK")

        elif self.path == "/reset":
            # Reset all stateful counters between tests
            MockHandler.session_expire_triggered = False
            MockHandler.session_refresh_triggered = False
            MockHandler.session_refresh_login_count = 0
            MockHandler.session_refresh_active_session_id = FAKE_SESSION_ID
            self._respond(200, "OK")

        elif self.path == "/ipv4":
            self._respond(200, FAKE_IPV4)

        elif self.path == "/ipv6":
            self._respond(200, FAKE_IPV6)

        elif self.path == "/ipv4-garbage":
            # Returns non-IP text to test fallback behavior
            self._respond(200, "<!-- error page -->")

        elif self.path == "/ipv6-garbage":
            # Returns non-IP text for IPv6 fallback testing
            self._respond(200, "<!-- error page -->")

        else:
            self._respond(404, "Not Found")

    # ------------------------------------------------------------------
    # POST handler — dispatches to the correct API variant
    # ------------------------------------------------------------------
    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)
        try:
            request = json.loads(body)
        except json.JSONDecodeError:
            self._respond_json(400, {"status": "error", "longmessage": "Invalid JSON"})
            return

        action = request.get("action", "")

        # Map URL path to handler
        dispatch = {
            "/api":                 self._variant_normal,
            "/api-login-fail":      self._variant_login_fail,
            "/api-ip-changed":      self._variant_ip_changed,
            "/api-no-records":      self._variant_no_records,
            "/api-dup-records":     self._variant_dup_records,
            "/api-high-ttl":        self._variant_high_ttl,
            "/api-session-expire":  self._variant_session_expire,
            "/api-session-refresh": self._variant_session_refresh,
            "/api-dup-aaaa":        self._variant_dup_aaaa,
            "/api-ttl-update-fail": self._variant_ttl_update_fail,
            "/api-records-fail":    self._variant_records_fail,
            "/api-zone-fail":       self._variant_zone_fail,
            "/api-update-fail":     self._variant_update_fail,
            "/api-logout-fail":     self._variant_logout_fail,
        }

        handler = dispatch.get(self.path)
        if handler:
            handler(action, request)
        else:
            self._respond(404, "Not Found")

    # ==================================================================
    # Common action responses (shared across variants)
    # ==================================================================

    def _success_login(self, session_id=FAKE_SESSION_ID):
        """Respond with a successful login."""
        self._respond_json(200, {
            "serverrequestid": "test",
            "clientrequestid": "",
            "action": "login",
            "status": "success",
            "statuscode": 2000,
            "shortmessage": "Login successful",
            "longmessage": "Session has been created.",
            "responsedata": {"apisessionid": session_id},
        })

    def _success_logout(self):
        """Respond with a successful logout."""
        self._respond_json(200, {
            "serverrequestid": "test",
            "clientrequestid": "",
            "action": "logout",
            "status": "success",
            "statuscode": 2000,
            "shortmessage": "Logout successful",
            "longmessage": "Session has been terminated.",
            "responsedata": "",
        })

    def _success_dns_zone(self, request, ttl="300"):
        """Respond with DNS zone info. TTL is configurable for testing."""
        self._respond_json(200, {
            "serverrequestid": "test",
            "clientrequestid": "",
            "action": "infoDnsZone",
            "status": "success",
            "statuscode": 2000,
            "shortmessage": "DNS zone info",
            "longmessage": "DNS zone information retrieved.",
            "responsedata": {
                "name": request["param"].get("domainname", "example.com"),
                "ttl": ttl,
                "serial": "2024010101",
                "refresh": "28800",
                "retry": "7200",
                "expire": "1209600",
                "dnssecstatus": False,
            },
        })

    def _success_dns_records(self, records):
        """Respond with DNS records."""
        self._respond_json(200, {
            "serverrequestid": "test",
            "clientrequestid": "",
            "action": "infoDnsRecords",
            "status": "success",
            "statuscode": 2000,
            "shortmessage": "DNS records found",
            "longmessage": "DNS records retrieved.",
            "responsedata": {"dnsrecords": records},
        })

    def _success_update_records(self, request):
        """Accept a DNS record update."""
        self._respond_json(200, {
            "serverrequestid": "test",
            "clientrequestid": "",
            "action": "updateDnsRecords",
            "status": "success",
            "statuscode": 2000,
            "shortmessage": "DNS records updated",
            "longmessage": "DNS records have been updated.",
            "responsedata": {
                "dnsrecords": request["param"].get("dnsrecordset", {}).get("dnsrecords", []),
            },
        })

    def _success_update_zone(self, request):
        """Accept a DNS zone update (e.g. TTL change)."""
        self._respond_json(200, {
            "serverrequestid": "test",
            "clientrequestid": "",
            "action": "updateDnsZone",
            "status": "success",
            "statuscode": 2000,
            "shortmessage": "DNS zone updated",
            "longmessage": "DNS zone has been updated.",
            "responsedata": request["param"].get("dnszone", {}),
        })

    def _error_4001(self, action):
        """Respond with API error 4001 (expired session)."""
        self._respond_json(200, {
            "serverrequestid": "test",
            "clientrequestid": "",
            "action": action,
            "status": "error",
            "statuscode": 4001,
            "shortmessage": "Validation Error",
            "longmessage": "The session id is not in a valid format.",
            "responsedata": "",
        })

    def _unknown_action(self, action):
        """Respond with an unknown action error."""
        self._respond_json(200, {
            "serverrequestid": "test",
            "clientrequestid": "",
            "action": action,
            "status": "error",
            "statuscode": 5000,
            "shortmessage": "Unknown action",
            "longmessage": f"Action '{action}' is not supported by this mock.",
            "responsedata": "",
        })

    # ------------------------------------------------------------------
    # Standard DNS records: A and AAAA for hostname "@"
    # ------------------------------------------------------------------

    @staticmethod
    def _default_records(ipv4=FAKE_IPV4, ipv6=FAKE_IPV6):
        """Return standard DNS records. IP addresses can be overridden."""
        return [
            {
                "id": "12345",
                "hostname": "@",
                "type": "A",
                "priority": "0",
                "destination": ipv4,
                "deleterecord": False,
                "state": "yes",
            },
            {
                "id": "12346",
                "hostname": "@",
                "type": "AAAA",
                "priority": "0",
                "destination": ipv6,
                "deleterecord": False,
                "state": "yes",
            },
        ]

    # ==================================================================
    # API variant handlers
    # ==================================================================

    def _variant_normal(self, action, request):
        """Normal happy path. Records match the current public IP → no update."""
        if action == "login":
            self._success_login()
        elif action == "logout":
            self._success_logout()
        elif action == "infoDnsZone":
            self._success_dns_zone(request)
        elif action == "infoDnsRecords":
            self._success_dns_records(self._default_records())
        elif action == "updateDnsRecords":
            self._success_update_records(request)
        elif action == "updateDnsZone":
            self._success_update_zone(request)
        else:
            self._unknown_action(action)

    def _variant_login_fail(self, action, request):
        """Login always fails with error 4013 (wrong credentials)."""
        self._respond_json(200, {
            "serverrequestid": "test",
            "clientrequestid": "",
            "action": action,
            "status": "error",
            "statuscode": 4013,
            "shortmessage": "Validation Error",
            "longmessage": "Wrong API credentials.",
            "responsedata": "",
        })

    def _variant_ip_changed(self, action, request):
        """DNS records contain a stale IP (1.1.1.1) that differs from the
        public IP returned by /ipv4. This triggers the update path."""
        if action == "login":
            self._success_login()
        elif action == "logout":
            self._success_logout()
        elif action == "infoDnsZone":
            self._success_dns_zone(request)
        elif action == "infoDnsRecords":
            # Return records with a DIFFERENT IP than what /ipv4 returns
            self._success_dns_records(self._default_records(ipv4="1.1.1.1", ipv6="::1"))
        elif action == "updateDnsRecords":
            self._success_update_records(request)
        elif action == "updateDnsZone":
            self._success_update_zone(request)
        else:
            self._unknown_action(action)

    def _variant_no_records(self, action, request):
        """Returns no DNS records at all. The script should create new records."""
        if action == "login":
            self._success_login()
        elif action == "logout":
            self._success_logout()
        elif action == "infoDnsZone":
            self._success_dns_zone(request)
        elif action == "infoDnsRecords":
            # Empty records → triggers record creation in the script
            self._success_dns_records([])
        elif action == "updateDnsRecords":
            self._success_update_records(request)
        elif action == "updateDnsZone":
            self._success_update_zone(request)
        else:
            self._unknown_action(action)

    def _variant_dup_records(self, action, request):
        """Returns duplicate A records for hostname '@'.
        The script should exit with an error."""
        if action == "login":
            self._success_login()
        elif action == "logout":
            self._success_logout()
        elif action == "infoDnsZone":
            self._success_dns_zone(request)
        elif action == "infoDnsRecords":
            # Two A records with the same hostname → triggers "multiple records" error
            dup_records = [
                {
                    "id": "12345",
                    "hostname": "@",
                    "type": "A",
                    "priority": "0",
                    "destination": FAKE_IPV4,
                    "deleterecord": False,
                    "state": "yes",
                },
                {
                    "id": "99999",
                    "hostname": "@",
                    "type": "A",
                    "priority": "0",
                    "destination": "10.0.0.1",
                    "deleterecord": False,
                    "state": "yes",
                },
            ]
            self._success_dns_records(dup_records)
        elif action == "updateDnsRecords":
            self._success_update_records(request)
        elif action == "updateDnsZone":
            self._success_update_zone(request)
        else:
            self._unknown_action(action)

    def _variant_high_ttl(self, action, request):
        """Returns a DNS zone with TTL=3600. With CHANGE_TTL=true in config,
        the script should lower it to 300."""
        if action == "login":
            self._success_login()
        elif action == "logout":
            self._success_logout()
        elif action == "infoDnsZone":
            self._success_dns_zone(request, ttl="3600")
        elif action == "infoDnsRecords":
            self._success_dns_records(self._default_records())
        elif action == "updateDnsRecords":
            self._success_update_records(request)
        elif action == "updateDnsZone":
            self._success_update_zone(request)
        else:
            self._unknown_action(action)

    def _variant_session_expire(self, action, request):
        """First non-login action returns error 4001 (expired session).
        The script should re-login and retry. Subsequent actions succeed."""
        if action == "login":
            self._success_login()
            return

        if action == "logout":
            self._success_logout()
            return

        # First non-login/logout action: return 4001 once
        if not MockHandler.session_expire_triggered:
            MockHandler.session_expire_triggered = True
            self._error_4001(action)
            return

        # After re-login: process normally
        if action == "infoDnsZone":
            self._success_dns_zone(request)
        elif action == "infoDnsRecords":
            self._success_dns_records(self._default_records())
        elif action == "updateDnsRecords":
            self._success_update_records(request)
        elif action == "updateDnsZone":
            self._success_update_zone(request)
        else:
            self._unknown_action(action)

    def _variant_session_refresh(self, action, request):
        """First non-login action returns 4001 and forces a new session ID.
        Subsequent requests must use the refreshed session without another 4001."""
        if action == "login":
            MockHandler.session_refresh_login_count += 1
            if MockHandler.session_refresh_login_count == 1:
                session_id = FAKE_SESSION_ID
            else:
                session_id = "test-session-id-refreshed"
            MockHandler.session_refresh_active_session_id = session_id
            self._success_login(session_id)
            return

        if action == "logout":
            if request["param"].get("apisessionid") != MockHandler.session_refresh_active_session_id:
                self._error_4001(action)
            else:
                self._success_logout()
            return

        if not MockHandler.session_refresh_triggered:
            MockHandler.session_refresh_triggered = True
            self._error_4001(action)
            return

        if request["param"].get("apisessionid") != MockHandler.session_refresh_active_session_id:
            self._error_4001(action)
            return

        if action == "infoDnsZone":
            self._success_dns_zone(request)
        elif action == "infoDnsRecords":
            self._success_dns_records(self._default_records())
        elif action == "updateDnsRecords":
            self._success_update_records(request)
        elif action == "updateDnsZone":
            self._success_update_zone(request)
        else:
            self._unknown_action(action)

    def _variant_dup_aaaa(self, action, request):
        """Returns normal A records but duplicate AAAA records for hostname '@'.
        Use with USE_IPV4=false, USE_IPV6=true to test AAAA duplicate error."""
        if action == "login":
            self._success_login()
        elif action == "logout":
            self._success_logout()
        elif action == "infoDnsZone":
            self._success_dns_zone(request)
        elif action == "infoDnsRecords":
            records = [
                {
                    "id": "12345",
                    "hostname": "@",
                    "type": "A",
                    "priority": "0",
                    "destination": FAKE_IPV4,
                    "deleterecord": False,
                    "state": "yes",
                },
                {
                    "id": "12346",
                    "hostname": "@",
                    "type": "AAAA",
                    "priority": "0",
                    "destination": FAKE_IPV6,
                    "deleterecord": False,
                    "state": "yes",
                },
                {
                    "id": "99999",
                    "hostname": "@",
                    "type": "AAAA",
                    "priority": "0",
                    "destination": "::2",
                    "deleterecord": False,
                    "state": "yes",
                },
            ]
            self._success_dns_records(records)
        elif action == "updateDnsRecords":
            self._success_update_records(request)
        elif action == "updateDnsZone":
            self._success_update_zone(request)
        else:
            self._unknown_action(action)

    def _variant_ttl_update_fail(self, action, request):
        """Like high_ttl but updateDnsZone returns error.
        Tests the 'Failed to set TTL... Continuing.' non-fatal path."""
        if action == "login":
            self._success_login()
        elif action == "logout":
            self._success_logout()
        elif action == "infoDnsZone":
            self._success_dns_zone(request, ttl="3600")
        elif action == "infoDnsRecords":
            self._success_dns_records(self._default_records())
        elif action == "updateDnsRecords":
            self._success_update_records(request)
        elif action == "updateDnsZone":
            self._respond_json(200, {
                "serverrequestid": "test",
                "clientrequestid": "",
                "action": "updateDnsZone",
                "status": "error",
                "statuscode": 5000,
                "shortmessage": "Zone update failed",
                "longmessage": "Could not update DNS zone.",
                "responsedata": "",
            })
        else:
            self._unknown_action(action)

    def _variant_records_fail(self, action, request):
        """Login and infoDnsZone succeed, but infoDnsRecords fails."""
        if action == "login":
            self._success_login()
        elif action == "logout":
            self._success_logout()
        elif action == "infoDnsZone":
            self._success_dns_zone(request)
        elif action == "infoDnsRecords":
            self._respond_json(200, {
                "serverrequestid": "test",
                "clientrequestid": "",
                "action": "infoDnsRecords",
                "status": "error",
                "statuscode": 5000,
                "shortmessage": "Records error",
                "longmessage": "Could not retrieve DNS records.",
                "responsedata": "",
            })
        elif action == "updateDnsRecords":
            self._success_update_records(request)
        elif action == "updateDnsZone":
            self._success_update_zone(request)
        else:
            self._unknown_action(action)

    def _variant_zone_fail(self, action, request):
        """Login succeeds but infoDnsZone fails."""
        if action == "login":
            self._success_login()
        elif action == "logout":
            self._success_logout()
        elif action == "infoDnsZone":
            self._respond_json(200, {
                "serverrequestid": "test",
                "clientrequestid": "",
                "action": "infoDnsZone",
                "status": "error",
                "statuscode": 5000,
                "shortmessage": "Zone error",
                "longmessage": "Could not retrieve DNS zone info.",
                "responsedata": "",
            })
        else:
            self._unknown_action(action)

    def _variant_update_fail(self, action, request):
        """Everything works except updateDnsRecords, which fails."""
        if action == "login":
            self._success_login()
        elif action == "logout":
            self._success_logout()
        elif action == "infoDnsZone":
            self._success_dns_zone(request)
        elif action == "infoDnsRecords":
            # Return stale IP to trigger an update attempt
            self._success_dns_records(self._default_records(ipv4="1.1.1.1", ipv6="::1"))
        elif action == "updateDnsRecords":
            self._respond_json(200, {
                "serverrequestid": "test",
                "clientrequestid": "",
                "action": "updateDnsRecords",
                "status": "error",
                "statuscode": 5000,
                "shortmessage": "Update failed",
                "longmessage": "Could not update DNS records.",
                "responsedata": "",
            })
        elif action == "updateDnsZone":
            self._success_update_zone(request)
        else:
            self._unknown_action(action)

    def _variant_logout_fail(self, action, request):
        """Everything works but logout fails."""
        if action == "login":
            self._success_login()
        elif action == "logout":
            self._respond_json(200, {
                "serverrequestid": "test",
                "clientrequestid": "",
                "action": "logout",
                "status": "error",
                "statuscode": 5000,
                "shortmessage": "Logout failed",
                "longmessage": "Could not terminate session.",
                "responsedata": "",
            })
        elif action == "infoDnsZone":
            self._success_dns_zone(request)
        elif action == "infoDnsRecords":
            self._success_dns_records(self._default_records())
        elif action == "updateDnsRecords":
            self._success_update_records(request)
        elif action == "updateDnsZone":
            self._success_update_zone(request)
        else:
            self._unknown_action(action)

    # ==================================================================
    # Response helpers
    # ==================================================================

    def _respond(self, status, body):
        """Send a plain-text response."""
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(body.encode())

    def _respond_json(self, status, data):
        """Send a JSON response (mimicking the netcup API format)."""
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())


class DualStackHTTPServer(HTTPServer):
    """HTTP server that listens on both IPv4 and IPv6 loopback."""
    address_family = socket.AF_INET6

    def server_bind(self):
        # Allow dual-stack: accept both IPv4 and IPv6 connections
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18741
    server = DualStackHTTPServer(("::", port), MockHandler)
    server.serve_forever()
