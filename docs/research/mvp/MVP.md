# Code Server

Here is the complete step‑by‑step guide to set up code-server on your server so you can access VS Code from your Huawei tablet via a browser. Since you have a server available 24/7, we'll make it properly secure with HTTPS.

---

Prerequisites

· A Linux server (Ubuntu 20.04–24.04 recommended)
· A non‑root user with sudo privileges
· A domain name pointing to your server’s public IP (e.g., code.example.com)
· Ports 80 and 443 open on your firewall
· Your Huawei tablet with a browser

---

Step 1: Update System & Install Dependencies

SSH into your server and run:

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget gnupg nginx certbot python3-certbot-nginx
```



---

Step 2: Install code-server

The easiest way is using the official installation script:

```bash
curl -fsSL https://code-server.dev/install.sh | sh
```

This automatically installs the latest version and sets up a systemd service.

Alternative – manual .deb install (if you need a specific version):

```bash
wget https://github.com/coder/code-server/releases/download/v4.96.4/code-server_4.96.4_amd64.deb
sudo dpkg -i code-server_4.96.4_amd64.deb
sudo apt --fix-broken install
```



---

Step 3: Configure code-server

Edit the config file to disable SSL (since Nginx will handle it) and set a password:

```bash
nano ~/.config/code-server/config.yaml
```

Modify it as follows:

```yaml
bind-addr: 127.0.0.1:8080
auth: password
password: "your-strong-password-here"
cert: false
```

· 127.0.0.1:8080 binds only to localhost – Nginx will act as the public gateway
· Set a strong password – this is your login for the web IDE

Save (Ctrl+X, then Y, then Enter).

---

Step 4: Start code-server as a systemd service

The install script already created a systemd service. Start and enable it now:

```bash
sudo systemctl daemon-reload
sudo systemctl start code-server@$USER
sudo systemctl enable code-server@$USER
sudo systemctl status code-server@$USER
```



You should see Active: active (running).

---

Step 5: Set Up Nginx as Reverse Proxy

Create an Nginx config file:

```bash
sudo nano /etc/nginx/sites-available/code-server
```

Paste this configuration (replace code.example.com with your actual domain):

```nginx
server {
    listen 80;
    server_name code.example.com;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

The WebSocket settings are critical for code-server to work properly.

Enable the site and test Nginx:

```bash
sudo ln -s /etc/nginx/sites-available/code-server /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

---

Step 6: Secure with HTTPS (Let's Encrypt)

Run Certbot to get a free SSL certificate:

```bash
sudo certbot --nginx -d code.example.com
```

Follow the prompts – it will automatically update your Nginx config to use HTTPS.

Certbot also sets up auto‑renewal, so your certificate stays valid.

---

Step 7: Access from Your Huawei Tablet

Open the browser on your tablet and go to:

```
https://code.example.com
```

You’ll see a login screen – enter the password you set in Step 3.

---

Optional: SSH Port Forwarding (No Domain / Extra Secure)

If you don’t have a domain, you can access code-server via SSH tunnelling from your tablet. On your tablet (using a terminal app like Termux), run:

```bash
ssh -L 8080:127.0.0.1:8080 user@your-server-ip
```

Then open http://127.0.0.1:8080 in the tablet browser.

---

Troubleshooting Quick Tips

Issue Solution
Service not starting Check logs: sudo journalctl -u code-server@$USER -f
Permission errors Run sudo chown -R $USER:$USER ~/.config/code-server
Can't log in Verify password in ~/.config/code-server/config.yaml and restart service
WebSocket errors Ensure the Upgrade and Connection headers are in your Nginx config
Port 8080 already in use Change bind-addr to a different port and update Nginx proxy_pass accordingly

For deeper debugging, run code-server with --log debug or check Nginx logs at /var/log/nginx/error.log.

---

You now have a fully functional, HTTPS‑secured VS Code environment accessible from your Huawei tablet anywhere. Let me know if you need help with any specific step! 😊
