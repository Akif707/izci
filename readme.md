# 🔍 IZCI — Professional Recon Framework

Automated reconnaissance tool for bug bounty hunters and security researchers.

## ⚠️ Legal Disclaimer
This tool is intended for **authorized security testing only**.
Only use on systems you have **explicit written permission** to test.
The author is not responsible for any misuse or damage.

## Features
- Subdomain enumeration (amass, sublist3r, crt.sh)
- Live host detection (httpx)
- Port scanning (nmap)
- Directory bruteforce (gobuster)
- API endpoint discovery (kiterunner)
- Subdomain takeover detection (subjack)
- Wayback Machine URL harvesting
- WAF/CDN evasion (rate limiting + UA rotation)

## Requirements
\`\`\`bash
sudo apt install -y seclists dirb subjack amass golang whatweb dnsx httpx-toolkit
\`\`\`

## Usage
\`\`\`bash
chmod +x izci.sh
sudo ./izci.sh <target> [profile]
\`\`\`

## Profiles
| Profile | Description |
|---|---|
| `stealth` | Slow, maximum WAF/CDN evasion |
| `normal` | Balanced (default) |
| `aggressive` | Fast, no limits (lab/trusted env) |

## Examples
\`\`\`bash
sudo ./izci.sh example.com
sudo ./izci.sh example.com stealth
sudo ./izci.sh example.com aggressive
\`\`\`
