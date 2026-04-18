#!/bin/bash
# -----------------------------------------------------------------------------
### IZCI - MÜKƏMMƏL PROFESSIONAL RECON SKRİPTİ
### Məqsəd: Hədəf domen üzərində ən geniş kapsamlı zəiflik aşkarlanması
### İstifadə: sudo ./izci.sh hedef.com [profil]
### Profillər: stealth | normal | aggressive  (default: normal)
### Tələblər: sudo apt install -y seclists dirb subjack amass golang whatweb dnsx httpx-toolkit
# -----------------------------------------------------------------------------

# set -e .
set -u

# ------------------------------ RƏNGLƏR --------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ------------------------------ İLK YOXLAMALAR ------------------------------
if [ $# -eq 0 ]; then
    echo -e "${RED}İstifadə: $0 <hədəf_domen> [profil]${NC}"
    echo -e "${YELLOW}Profillər:${NC}"
    echo -e "  ${CYAN}stealth${NC}    — Çox yavaş, maksimum gizlilik (WAF/CDN bypass üçün)"
    echo -e "  ${GREEN}normal${NC}     — Balanslaşdırılmış (default)"
    echo -e "  ${RED}aggressive${NC} — Sürətli, limit yoxdur (trusted/lab mühit)"
    echo -e "${YELLOW}Nümunə: $0 example.com stealth${NC}"
    exit 1
fi

readonly TARGET="$1"
readonly PROFILE="${2:-normal}"
readonly BASE_DIR="./arwad_${TARGET}_$(date +"%Y%m%d_%H%M%S")"
readonly LISTS_DIR="${BASE_DIR}/lists"
readonly OUTPUT_DIR="${BASE_DIR}/output"
readonly LOG_FILE="${BASE_DIR}/arwad.log"

# ------------------------------ PROFİL KONFİQURASİYASI ------------------------------
case "$PROFILE" in
    stealth)
        THREADS_HIGH=5
        THREADS_MEDIUM=3
        REQ_DELAY=2.5
        BURST_SIZE=10
        BURST_PAUSE=15
        NMAP_TIMING=1
        HTTPX_RATE=5
        GOBUSTER_DELAY=2000
        UA_ROTATE=1
        echo -e "${MAGENTA}[PROFIL] STEALTH — Maksimum gizlilik, yavaş skan${NC}"
        ;;
    aggressive)
        THREADS_HIGH=100
        THREADS_MEDIUM=50
        REQ_DELAY=0
        BURST_SIZE=0
        BURST_PAUSE=0
        NMAP_TIMING=5
        HTTPX_RATE=0
        GOBUSTER_DELAY=0
        UA_ROTATE=0
        echo -e "${RED}[PROFIL] AGGRESSIVE — Maksimum sürət, limit yoxdur${NC}"
        ;;
    normal|*)
        THREADS_HIGH=25
        THREADS_MEDIUM=12
        REQ_DELAY=0.5
        BURST_SIZE=30
        BURST_PAUSE=5
        NMAP_TIMING=3
        HTTPX_RATE=25
        GOBUSTER_DELAY=500
        UA_ROTATE=1
        echo -e "${GREEN}[PROFIL] NORMAL — Balanslaşdırılmış skan${NC}"
        ;;
esac

# ------------------------------ USER-AGENT POOL ------------------------------
UA_POOL=(
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36"
    "Mozilla/5.0 (X11; Linux x86_64; rv:123.0) Gecko/20100101 Firefox/123.0"
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:122.0) Gecko/20100101 Firefox/122.0"
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_3_1) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.3.1 Safari/605.1.15"
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36 Edg/122.0.0.0"
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.3 Mobile/15E148 Safari/604.1"
    "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.6261.90 Mobile Safari/537.36"
    "Googlebot/2.1 (+http://www.google.com/bot.html)"
    "Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)"
)

get_random_ua() {
    echo "${UA_POOL[$((RANDOM % ${#UA_POOL[@]}))]}"
}

# ------------------------------ RATE LIMIT FUNKSİYALARI ------------------------------
_REQ_COUNTER=0

rate_limit() {
    if [ "$PROFILE" = "aggressive" ]; then
        return
    fi

    _REQ_COUNTER=$((_REQ_COUNTER + 1))

    if [ "$BURST_SIZE" -gt 0 ] && [ "$((_REQ_COUNTER % BURST_SIZE))" -eq 0 ]; then
        log "  [Rate Limit] ${_REQ_COUNTER} sorğu — ${BURST_PAUSE}s fasilə..."
        sleep "$BURST_PAUSE"
    fi

    if [ "$(echo "$REQ_DELAY > 0" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
        sleep "$REQ_DELAY"
    fi
}

rate_curl() {
    local url="$1"
    shift
    rate_limit

    local ua
    if [ "$UA_ROTATE" -eq 1 ]; then
        ua=$(get_random_ua)
    else
        ua="curl/8.0.0"
    fi

    curl -s \
        -A "$ua" \
        -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
        -H "Accept-Language: en-US,en;q=0.5" \
        -H "Accept-Encoding: gzip, deflate, br" \
        -H "DNT: 1" \
        -H "Connection: keep-alive" \
        --compressed \
        --max-time 30 \
        "$@" \
        "$url"
}

# ------------------------------ TRAP: Təmiz Çıxış ------------------------------
cleanup() {
    echo -e "\n${YELLOW}[!] Dayandırılır... Background proseslər sonlandırılır.${NC}"
    local pids
    pids=$(jobs -p 2>/dev/null)
    if [ -n "$pids" ]; then
        kill $pids 2>/dev/null
        wait $pids 2>/dev/null
    fi
    echo -e "${RED}[!] Skript dayandırıldı. Mövcud nəticələr: ${BASE_DIR}${NC}"
    exit 1
}
trap cleanup INT TERM

# ------------------------------ SİSTEM ANALİZİ --------------------------------
echo -e "${CYAN}[*] Sistem analiz edilir...${NC}"

ORIGINAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(eval echo ~"$ORIGINAL_USER")
export PATH="$PATH:$USER_HOME/go/bin"

SECLISTS_PATH="/usr/share/seclists"
echo -e "${GREEN}[+] Seclists: ${SECLISTS_PATH}${NC}"

SUBDOMAIN_WORDLIST="/usr/share/seclists/Discovery/DNS/subdomains-top1million-5000.txt"
if [ ! -f "$SUBDOMAIN_WORDLIST" ]; then
    SUBDOMAIN_WORDLIST="/usr/share/seclists/Discovery/DNS/subdomains-top1million-110000.txt"
fi
echo -e "${GREEN}[+] Subdomain wordlist: ${SUBDOMAIN_WORDLIST}${NC}"

DIR_WORDLIST="/usr/share/dirb/wordlists/common.txt"
echo -e "${GREEN}[+] Dirb wordlist: ${DIR_WORDLIST}${NC}"

API_WORDLIST="/usr/share/seclists/Discovery/Web-Content/api/api-endpoints.txt"
if [ ! -f "$API_WORDLIST" ]; then
    API_WORDLIST="/usr/share/seclists/Discovery/Web-Content/api/api-endpoints-res.txt"
fi
echo -e "${GREEN}[+] API wordlist: ${API_WORDLIST}${NC}"

SUBJACK_FINGERPRINTS="/usr/share/subjack/fingerprints.json"
echo -e "${GREEN}[+] Subjack fingerprints: ${SUBJACK_FINGERPRINTS}${NC}"

WAYBACK_PATH="/home/kali/go/bin/waybackurls"

# ------------------------------ QOVLUQ YARATMA ------------------------------
mkdir -p "${LISTS_DIR}" "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}/gobuster" "${OUTPUT_DIR}/kiterunner" "${OUTPUT_DIR}/nmap" "${OUTPUT_DIR}/whatweb"

# ------------------------------ FUNKSİYALAR ------------------------------
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "${LOG_FILE}"
}

error() {
    echo -e "${RED}[XƏTA]${NC} $1" | tee -a "${LOG_FILE}"
    exit 1
}

warning() {
    echo -e "${YELLOW}[XƏBƏRDARLIQ]${NC} $1" | tee -a "${LOG_FILE}"
}

success() {
    echo -e "${GREEN}[OK]${NC} $1" | tee -a "${LOG_FILE}"
}

check_tool() {
    if command -v "$1" &> /dev/null; then
        success "$1 hazır"
        return 0
    else
        warning "$1 tapılmadı."
        return 1
    fi
}

# ------------------------------ Paralel İcra ------------------------------
declare -a BG_PIDS=()
declare -a BG_LABELS=()

run_parallel() {
    local label="$1"
    shift
    "$@" &
    local pid=$!
    BG_PIDS+=("$pid")
    BG_LABELS+=("$label")
}

wait_all_parallel() {
    local has_error=0
    local i=0
    for pid in "${BG_PIDS[@]}"; do
        local label="${BG_LABELS[$i]}"
        if wait "$pid"; then
            success "${label} tamamlandı"
        else
            local exit_code=$?
            warning "${label} xəta ilə tamamlandı (exit: ${exit_code}) — davam edilir"
            has_error=1
        fi
        i=$((i + 1))
    done
    BG_PIDS=()
    BG_LABELS=()
    return $has_error
}

# ------------------------------ ALƏTLƏRİ YOXLA ------------------------------
log "=================== ARWAD PRO V3.0 BAŞLAYIR ==================="
log "Hədəf:       ${TARGET}"
log "Profil:      ${PROFILE}"
log "İş qovluğu: ${BASE_DIR}"
log ""

log "--- Alətlər yoxlanılır ---"
check_tool "theharvester"  || warning "theHarvester olmadan davam edirik."
check_tool "jq"            || warning "jq olmadan JSON emalı çətinləşəcək."
check_tool "curl"          || error "curl olmadan işləyə bilmərik."
check_tool "bc"            || warning "bc olmadan float delay işləməyəcək."
check_tool "sublist3r"     || warning "sublist3r olmadan davam edirik."
check_tool "nmap"          || warning "nmap olmadan port skanı olmayacaq."
check_tool "whatweb"       || warning "whatweb olmadan texnologiya aşkarlanmayacaq."
check_tool "gobuster"      || warning "gobuster olmadan kataloq skanı olmayacaq."
check_tool "dnsx"          || warning "dnsx olmadan DNS yoxlanışı olmayacaq."
check_tool "subjack"       || warning "subjack olmadan takeover yoxlanışı olmayacaq."
check_tool "amass"         || warning "amass olmadan subdomain kəşfi zəifləyəcək."
check_tool "httpx-toolkit" || warning "httpx olmadan canlı server aşkarlanmayacaq."

if ! command -v "kr" &> /dev/null;   then warning "kr (kiterunner) tapılmadı. API skanı olmayacaq."; fi
if ! command -v "anew" &> /dev/null; then warning "anew tapılmadı."; fi

log ""

# ------------------------------ NMAP FLAG TƏYİNİ ------------------------------
if [ "$EUID" -eq 0 ]; then
    NMAP_SCAN_TYPE="-sS"
    success "Root aşkarlandı: nmap SYN scan (-sS)"
else
    NMAP_SCAN_TYPE="-sT"
    warning "Root deyil: nmap TCP connect scan (-sT)"
fi

# ------------------------------ PROFİL XÜLASƏSİ ------------------------------
log "--- Rate Limit Konfiqurasiyası ---"
log "  Thread (high/med):  ${THREADS_HIGH} / ${THREADS_MEDIUM}"
log "  Sorğu gecikmesi:    ${REQ_DELAY}s"
log "  Burst:              hər ${BURST_SIZE} sorğudan sonra ${BURST_PAUSE}s fasilə"
log "  httpx max-rate:     ${HTTPX_RATE} req/s"
log "  gobuster delay:     ${GOBUSTER_DELAY}ms"
log "  nmap timing:        -T${NMAP_TIMING}"
log "  UA rotasiyası:      $([ "$UA_ROTATE" -eq 1 ] && echo 'aktiv' || echo 'deaktiv')"
log ""

# ---------------------------- MƏRHƏLƏ 1: SUBDOMAIN KƏŞFİ --------------------------------
log "--- MƏRHƏLƏ 1: SUBDOMAIN KƏŞFİ ---"

if command -v theharvester &> /dev/null; then
    log "theHarvester işləyir..."
    theharvester -d "${TARGET}" -b baidu,bing,google,yahoo,linkedin \
        -f "${LISTS_DIR}/harvester.html" > /dev/null 2>&1 \
        || warning "theHarvester bəzi mənbələrdən nəticə ala bilmədi."
else
    warning "theHarvester olmadığı üçün keçildi."
fi

log "crt.sh məlumatları alınır..."
rate_curl "https://crt.sh/?q=%25.${TARGET}&output=json" 2>/dev/null | \
    jq -r '.[].name_value // empty' 2>/dev/null | \
    grep -E '^[a-zA-Z0-9.-]+\.'"${TARGET}"'$' | \
    sed 's/\*\.//g' | \
    sort -u > "${LISTS_DIR}/crt.txt"
success "crt.sh tamam: $(wc -l < "${LISTS_DIR}/crt.txt") subdomain"

if command -v sublist3r &> /dev/null; then
    log "Sublist3r işləyir..."
    sublist3r -d "${TARGET}" -t "${THREADS_MEDIUM}" \
        -o "${LISTS_DIR}/sublist3r_raw.txt" > /dev/null 2>&1
    grep -E "^[a-zA-Z0-9.-]+\.${TARGET}$" \
        "${LISTS_DIR}/sublist3r_raw.txt" 2>/dev/null \
        | sort -u > "${LISTS_DIR}/sublist3r.txt" \
        || touch "${LISTS_DIR}/sublist3r.txt"
    success "Sublist3r tamam: $(wc -l < "${LISTS_DIR}/sublist3r.txt") subdomain"
else
    warning "Sublist3r olmadığı üçün keçildi."
    touch "${LISTS_DIR}/sublist3r.txt"
fi

if command -v amass &> /dev/null; then
    log "Amass passive işləyir..."
    amass enum -passive -d "${TARGET}" \
        -o "${LISTS_DIR}/amass_passive.txt" > /dev/null 2>&1 \
        || touch "${LISTS_DIR}/amass_passive.txt"
    success "Amass passive: $(wc -l < "${LISTS_DIR}/amass_passive.txt" 2>/dev/null || echo 0) subdomain"

    if [ -f "$SUBDOMAIN_WORDLIST" ]; then
        log "Amass active bruteforce işləyir..."
        amass enum -active -d "${TARGET}" -brute -w "${SUBDOMAIN_WORDLIST}" \
            -o "${LISTS_DIR}/amass_active.txt" > /dev/null 2>&1 \
            || touch "${LISTS_DIR}/amass_active.txt"
        success "Amass active: $(wc -l < "${LISTS_DIR}/amass_active.txt" 2>/dev/null || echo 0) subdomain"
    else
        warning "Subdomain wordlist tapılmadı, Amass active keçildi."
        touch "${LISTS_DIR}/amass_active.txt"
    fi
else
    warning "Amass olmadığı üçün keçildi."
    touch "${LISTS_DIR}/amass_passive.txt"
    touch "${LISTS_DIR}/amass_active.txt"
fi

cat "${LISTS_DIR}/amass_passive.txt" "${LISTS_DIR}/amass_active.txt" 2>/dev/null \
    | sort -u > "${LISTS_DIR}/amass.txt"
success "Amass ümumi: $(wc -l < "${LISTS_DIR}/amass.txt" 2>/dev/null || echo 0) subdomain"

log "Bütün subdomain siyahıları birləşdirilir..."
cat "${LISTS_DIR}"/crt.txt \
    "${LISTS_DIR}"/sublist3r.txt \
    "${LISTS_DIR}"/amass.txt 2>/dev/null \
    | grep -E '^[a-zA-Z0-9.-]+\.'"${TARGET}"'$' \
    | sort -u > "${LISTS_DIR}/all_subdomains_raw.txt"
raw_count=$(wc -l < "${LISTS_DIR}/all_subdomains_raw.txt" 2>/dev/null || echo 0)
success "Ham subdomain sayısı: ${raw_count}"

subdomain_count=0

if [ -s "${LISTS_DIR}/all_subdomains_raw.txt" ] && command -v dnsx &> /dev/null; then
    log "DNS kontrolü (dnsx) işləyir..."
    DNSX_RATE_FLAG=""
    case "$PROFILE" in
        stealth)    DNSX_RATE_FLAG="-rate-limit 5"  ;;
        normal)     DNSX_RATE_FLAG="-rate-limit 50" ;;
        aggressive) DNSX_RATE_FLAG=""               ;;
    esac
    dnsx -l "${LISTS_DIR}/all_subdomains_raw.txt" \
        -a -silent -retry 2 \
        $DNSX_RATE_FLAG \
        | awk '{print $1}' | sort -u > "${LISTS_DIR}/subdomains_dns.txt"
    cp "${LISTS_DIR}/subdomains_dns.txt" "${LISTS_DIR}/subdomains_final.txt"
    subdomain_count=$(wc -l < "${LISTS_DIR}/subdomains_final.txt" 2>/dev/null || echo 0)
    success "Canlı subdomain sayısı: ${subdomain_count}"
elif [ -s "${LISTS_DIR}/all_subdomains_raw.txt" ]; then
    warning "dnsx yoxdur. Bütün subdomainlər istifadə olunacaq."
    cp "${LISTS_DIR}/all_subdomains_raw.txt" "${LISTS_DIR}/subdomains_final.txt"
    subdomain_count=$raw_count
else
    warning "Subdomain siyahısı boşdur."
    touch "${LISTS_DIR}/subdomains_final.txt"
    subdomain_count=0
fi

# ---------------------------- MƏRHƏLƏ 2: CANLI XİDMƏTLƏR --------------------------------
log ""
log "--- MƏRHƏLƏ 2: CANLI XİDMƏTLƏRİN TƏYİNİ ---"
live_count=0

if [ -s "${LISTS_DIR}/subdomains_final.txt" ] && command -v httpx-toolkit &> /dev/null; then
    log "Canlı veb serverlər aşkarlanır (httpx)..."

    HTTPX_RATE_FLAG=""
    if [ "$HTTPX_RATE" -gt 0 ] 2>/dev/null; then
        HTTPX_RATE_FLAG="-rate-limit ${HTTPX_RATE}"
    fi

    HTTPX_UA=$(get_random_ua)

    httpx-toolkit -l "${LISTS_DIR}/subdomains_final.txt" \
        -ports 80,443,8080,8443,8000,8888,3000,5000,7071,9090 \
        -threads "${THREADS_HIGH}" \
        -silent \
        -status-code \
        -title \
        -tech-detect \
        -follow-redirects \
        -H "User-Agent: ${HTTPX_UA}" \
        $HTTPX_RATE_FLAG \
        -o "${OUTPUT_DIR}/live_webservers.txt" \
        > /dev/null 2>&1
    live_count=$(wc -l < "${OUTPUT_DIR}/live_webservers.txt" 2>/dev/null || echo 0)
    success "Canlı veb server sayısı: ${live_count}"
else
    warning "Subdomain siyahısı boş və ya httpx yoxdur."
    touch "${OUTPUT_DIR}/live_webservers.txt"
    live_count=0
fi

if [ -s "${LISTS_DIR}/subdomains_final.txt" ] && command -v nmap &> /dev/null; then
    log "Port taraması başlıyor (nmap -T${NMAP_TIMING})..."
    nmap "${NMAP_SCAN_TYPE}" -sV \
        -T"${NMAP_TIMING}" \
        --top-ports 1000 --open \
        -iL "${LISTS_DIR}/subdomains_final.txt" \
        -oA "${OUTPUT_DIR}/nmap/nmap_scan" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        success "Nmap nəticələri ${OUTPUT_DIR}/nmap/ qovluğunda"
    else
        warning "Nmap skanı tam tamamlanmadı. Mövcud nəticələr saxlanıldı."
    fi
else
    warning "Subdomain siyahısı boş və ya nmap yoxdur. Nmap skanı keçildi."
fi

# ---------------------------- MƏRHƏLƏ 3: VEB TEXNOLOGİYA --------------------------------
log ""
log "--- MƏRHƏLƏ 3: VEB TEXNOLOGİYALARININ TƏYİNİ ---"

if [ -s "${OUTPUT_DIR}/live_webservers.txt" ]; then

    if command -v whatweb &> /dev/null; then
        log "Texnologiya aşkarlanması (whatweb) işləyir..."
        grep -oP 'https?://[^\s]+' "${OUTPUT_DIR}/live_webservers.txt" | \
        while IFS= read -r url; do
            rate_limit
            domain_name=$(echo "${url}" | sed -e 's|https\?://||' -e 's|/||g' -e 's|:|_|g')
            ua=$(get_random_ua)
            run_parallel "whatweb:${domain_name}" \
                whatweb -a 3 \
                    --user-agent "${ua}" \
                    "${url}" \
                    --log-verbose="${OUTPUT_DIR}/whatweb/${domain_name}.txt"
        done
        wait_all_parallel || warning "Bəzi whatweb skanları xəta ilə bitdi — davam edilir"
        cat "${OUTPUT_DIR}"/whatweb/*.txt 2>/dev/null > "${OUTPUT_DIR}/tech_stack.txt"
        success "Texnologiya məlumatları ${OUTPUT_DIR}/tech_stack.txt faylında"
    else
        warning "whatweb olmadığı üçün keçildi."
    fi

    if command -v gobuster &> /dev/null && [ -f "$DIR_WORDLIST" ]; then
        log "Kataloq skanı (gobuster) başlayır..."
        grep -oP 'https?://[^\s]+' "${OUTPUT_DIR}/live_webservers.txt" | \
        while IFS= read -r url; do
            rate_limit
            domain_name=$(echo "${url}" | sed -e 's|https\?://||' -e 's|/||g' -e 's|:|_|g')
            ua=$(get_random_ua)

            GOBUSTER_DELAY_FLAG=""
            if [ "$GOBUSTER_DELAY" -gt 0 ] 2>/dev/null; then
                GOBUSTER_DELAY_FLAG="--delay ${GOBUSTER_DELAY}ms"
            fi

            run_parallel "gobuster:${domain_name}" \
                gobuster dir \
                    -u "${url}" \
                    -w "${DIR_WORDLIST}" \
                    -t "${THREADS_MEDIUM}" \
                    -q \
                    --useragent "${ua}" \
                    $GOBUSTER_DELAY_FLAG \
                    -o "${OUTPUT_DIR}/gobuster/${domain_name}.txt"
        done
        wait_all_parallel || warning "Bəzi gobuster skanları xəta ilə bitdi — davam edilir"
        success "Gobuster nəticələri ${OUTPUT_DIR}/gobuster/ qovluğunda"
    else
        warning "Gobuster və ya wordlist tapılmadı. Kataloq skanı keçildi."
    fi

    if command -v kr &> /dev/null; then
        log "API endpoint skanı (kiterunner) başlayır..."
        grep -oP 'https?://[^\s]+' "${OUTPUT_DIR}/live_webservers.txt" | \
        while IFS= read -r url; do
            rate_limit
            domain_name=$(echo "${url}" | sed -e 's|https\?://||' -e 's|/||g' -e 's|:|_|g')

            KR_DELAY_FLAG=""
            case "$PROFILE" in
                stealth)    KR_DELAY_FLAG="--delay 3000" ;;
                normal)     KR_DELAY_FLAG="--delay 500"  ;;
                aggressive) KR_DELAY_FLAG=""              ;;
            esac

            run_parallel "kiterunner:${domain_name}" \
                kr scan "${url}" \
                    -A=apiroutes-210328 \
                    $KR_DELAY_FLAG \
                    --output "${OUTPUT_DIR}/kiterunner/${domain_name}.txt"
        done
        wait_all_parallel || warning "Bəzi kiterunner skanları xəta ilə bitdi — davam edilir"
        success "Kiterunner nəticələri ${OUTPUT_DIR}/kiterunner/ qovluğunda"
    else
        warning "Kiterunner tapılmadı. API skanı keçildi."
    fi

else
    warning "Canlı veb server tapılmadı. Veb analizi keçildi."
fi

# ---------------------------- MƏRHƏLƏ 4: ZƏİFLİK ANALİZİ --------------------------------
log ""
log "--- MƏRHƏLƏ 4: ZƏİFLİK ANALİZİ ---"

if [ -s "${LISTS_DIR}/subdomains_final.txt" ] && \
   command -v subjack &> /dev/null && \
   [ -f "$SUBJACK_FINGERPRINTS" ]; then
    log "Subdomain takeover yoxlanışı (subjack) işləyir..."
    subjack -w "${LISTS_DIR}/subdomains_final.txt" \
        -t "${THREADS_MEDIUM}" \
        -timeout 10 \
        -ssl \
        -c "${SUBJACK_FINGERPRINTS}" \
        -o "${OUTPUT_DIR}/takeover_results.txt" \
        > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        success "Takeover nəticələri ${OUTPUT_DIR}/takeover_results.txt faylında"
    else
        warning "Subjack xəta ilə tamamlandı. Mövcud nəticələr saxlanıldı."
    fi
else
    warning "Subjack keçildi (siyahı boş, alət yoxdur, və ya fingerprint tapılmadı)."
    touch "${OUTPUT_DIR}/takeover_results.txt"
fi

# ---------------------------- WAYBACK MACHINE ----------------------------
log "Wayback Machine URL-ləri toplanır..."

if [ -x "$WAYBACK_PATH" ]; then
    if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
        sudo -u "$SUDO_USER" "$WAYBACK_PATH" "$TARGET" 2>/dev/null \
            | sort -u > "${OUTPUT_DIR}/wayback_urls.txt"
    else
        "$WAYBACK_PATH" "$TARGET" 2>/dev/null \
            | sort -u > "${OUTPUT_DIR}/wayback_urls.txt"
    fi
else
    warning "waybackurls tapılmadı: $WAYBACK_PATH"
    touch "${OUTPUT_DIR}/wayback_urls.txt"
fi

if [ ! -s "${OUTPUT_DIR}/wayback_urls.txt" ]; then
    warning "waybackurls nəticə vermədi, curl ilə cəhd edilir..."
    rate_curl "http://web.archive.org/cdx/search/cdx?url=*.${TARGET}&output=json&fl=original&collapse=urlkey" \
        2>/dev/null | \
        jq -r '.[1:][] | .[0]' 2>/dev/null | \
        sort -u > "${OUTPUT_DIR}/wayback_urls.txt"
fi

url_count=$(wc -l < "${OUTPUT_DIR}/wayback_urls.txt" 2>/dev/null || echo 0)
success "Wayback URL sayısı: ${url_count}"

param_count=0
if [ -s "${OUTPUT_DIR}/wayback_urls.txt" ]; then
    grep -E '\?.*=' "${OUTPUT_DIR}/wayback_urls.txt" 2>/dev/null \
        | cut -d'?' -f1 | sort -u \
        > "${OUTPUT_DIR}/wayback_endpoints_with_params.txt"
    param_count=$(wc -l < "${OUTPUT_DIR}/wayback_endpoints_with_params.txt" 2>/dev/null || echo 0)
    success "Parametrli endpoint sayısı: ${param_count}"
else
    touch "${OUTPUT_DIR}/wayback_endpoints_with_params.txt"
fi

trap - INT TERM

# ---------------------------- HESABAT --------------------------------
log ""
log "=================== ARWAD PRO V3.0 TAMAMLANDI ==================="
log ""
success "Bütün nəticələr:            ${BASE_DIR}"
success "Profil:                     ${PROFILE}"
success "Canlı subdomain sayısı:     ${subdomain_count}"
success "Canlı veb server sayısı:    ${live_count}"
success "Wayback URL sayısı:         ${url_count}"
success "Parametrli endpoint sayısı: ${param_count}"
log ""
log "Nəticələri yoxlamaq üçün:"
echo -e "${CYAN}  ls -la ${BASE_DIR}/${NC}"
echo -e "${CYAN}  cat ${OUTPUT_DIR}/live_webservers.txt${NC}"
echo -e "${CYAN}  cat ${OUTPUT_DIR}/tech_stack.txt${NC}"
echo -e "${CYAN}  cat ${OUTPUT_DIR}/takeover_results.txt${NC}"
echo -e "${CYAN}  cat ${OUTPUT_DIR}/wayback_urls.txt | head -20${NC}"
log ""
log "=========================================================="
