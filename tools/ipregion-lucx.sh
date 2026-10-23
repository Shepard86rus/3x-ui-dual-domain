#!/usr/bin/env bash
# ipregion-lucx — форк ipregion для проверки IP наших нод (проект 3x-ui-dual-domain).
# Основан на XaksFlaX/ipregion-fixed, который основан на Davoyan/ipregion.
# Лицензия исходника — MIT, Copyright (c) 2024 Nikita Skryabin. Уведомление сохранено.
# Запуск прямо с GitHub:
#   bash <(curl -fsSL https://raw.githubusercontent.com/Shepard86rus/3x-ui-dual-domain/main/tools/ipregion-lucx.sh) --help

# print_cell strips color codes with an extended pattern: +([0-9;])
shopt -s extglob

# YYYY.MM.DD.N, N = change of the day. Bump on every change of this file (CI checks it)
SCRIPT_VERSION="2026.10.23.9"
# lucx fork: v0.2.0 = ipregion-fixed 2026.10.23.9 + проверка произвольного IP (первый аргумент),
# итог по-русски, --expect СТРАНА (код выхода 3 при расхождении), --no-doh, полный IP в шапке (--mask скрывает)
LUCX_VERSION="0.2.0"
# Вывод не в терминал (ssh, cron, файл, pipe): без цветов и без крутилки
INTERACTIVE=false
[[ -t 1 ]] && INTERACTIVE=true
SCRIPT_URL="https://github.com/XaksFlaX/ipregion-fixed"
DEPENDENCIES=("jq" "curl" "util-linux")
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"
# One temporary directory for the spinner, per-request statuses and parallel results
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ipregion_XXXXXX")
SPINNER_SERVICE_FILE="$WORK_DIR/spinner"
trap 'rm -rf "$WORK_DIR"' EXIT

SPOTIFY_API_KEY="142b583129b2df829de3656f9eb484e6"
SPOTIFY_CLIENT_ID="9a8d2f0ce77a4e248bb71fefcb557637"

# Google's list of regions where the Gemini API is available, one "- Country" per line
GEMINI_REGIONS_URL="https://ai.google.dev/gemini-api/docs/available-regions.md.txt"

# Countries whose name in Google's list differs from COUNTRY_NAMES word by word
declare -A GEMINI_REGION_NAMES=(
  [TR]="Türkiye"
  [VA]="Vatican City"
  [LA]="Laos"
  [BQ]="Caribbean Netherlands"
)

# True when $name matches a "- Region" line of $md: one set of significant words contains the other
# ("Korea (Republic of)" matches "South Korea", "Congo" matches "Republic of the Congo")
GEMINI_MATCH_FILTER='
  def stopwords: ["the", "of", "and", "republic", "island", "islands", "saint", "st"];
  def words: ascii_downcase | [splits("[^\\p{L}]+")] | map(select(. != "" and (IN(stopwords[]) | not))) | unique;
  ($name | words) as $wanted
  | ($wanted | length) > 0
    and ([$md | split("\n")[] | select(startswith("- ")) | .[2:] | words]
         | any(. as $region | (($wanted - $region) | length) == 0 or (($region - $wanted) | length) == 0))
'

# Public key of the Disney+ Android app, as used by vernette/ipregion
DISNEY_PLUS_API_KEY="ZGlzbmV5JmFuZHJvaWQmMS4wLjA.bkeb0m230uUhv8qrAXuNu39tbE_mD5EEhM_NAcohjyA"
DISNEY_PLUS_JSON_BODY='{"query":"\n     mutation registerDevice($registerDevice: RegisterDeviceInput!) {\n       registerDevice(registerDevice: $registerDevice) {\n         __typename\n       }\n     }\n     ","variables":{"registerDevice":{"applicationRuntime":"android","attributes":{"operatingSystem":"Android","operatingSystemVersion":"13"},"deviceFamily":"android","deviceLanguage":"en","deviceProfile":"phone","devicePlatformId":"android"}},"operationName":"registerDevice"}'

VERBOSE=false
JSON_OUTPUT=false
GROUPS_TO_SHOW="all"
CURL_TIMEOUT=6
CURL_RETRIES=1
PARALLEL_JOBS=6
UPDATE_CHECK=false
TARGET_IP=""
EXPECT_CC=""
USE_DOH=true
MASK_IP=false
VERDICT_EXIT=0
UPDATE_CHECK_URL="https://raw.githubusercontent.com/XaksFlaX/ipregion-fixed/main/ipregion.sh"
UPDATE_CHECK_PID=""
LATEST_VERSION=""
IPV4_ONLY=false
IPV6_ONLY=false
PROXY_ADDR=""
INTERFACE_NAME=""

RESULT_JSON=""
ARR_PRIMARY=()
ARR_CUSTOM=()
ARR_CDN=()
ARR_NETWORK=()

COLOR_HEADER="1;36"
COLOR_SERVICE="0;92"
COLOR_HEART="1;31"
COLOR_URL="1;90"
COLOR_ASN="1;33"
COLOR_TABLE_HEADER="1;97"
COLOR_TABLE_VALUE="1"
COLOR_NULL="0;90"
COLOR_ERROR="1;31"
COLOR_WARN="1;33"
COLOR_INFO="1;36"
COLOR_RESET="0"

LOG_INFO="INFO"
LOG_WARN="WARNING"
LOG_ERROR="ERROR"

SELECTED_DOH_ARGS=()

declare -A DEPENDENCY_COMMANDS=(
  [jq]="jq"
  [curl]="curl"
  [util-linux]="column"
)

declare -A COUNTRY_NAMES=(
  [AF]="Afghanistan"
  [AX]="Åland Islands"
  [AL]="Albania"
  [DZ]="Algeria"
  [AS]="American Samoa"
  [AD]="Andorra"
  [AO]="Angola"
  [AI]="Anguilla"
  [AQ]="Antarctica"
  [AG]="Antigua and Barbuda"
  [AR]="Argentina"
  [AM]="Armenia"
  [AW]="Aruba"
  [AU]="Australia"
  [AT]="Austria"
  [AZ]="Azerbaijan"
  [BS]="Bahamas"
  [BH]="Bahrain"
  [BD]="Bangladesh"
  [BB]="Barbados"
  [BY]="Belarus"
  [BE]="Belgium"
  [BZ]="Belize"
  [BJ]="Benin"
  [BM]="Bermuda"
  [BT]="Bhutan"
  [BO]="Bolivia"
  [BQ]="Bonaire, Sint Eustatius and Saba"
  [BA]="Bosnia and Herzegovina"
  [BW]="Botswana"
  [BV]="Bouvet Island"
  [BR]="Brazil"
  [IO]="British Indian Ocean Territory"
  [BN]="Brunei Darussalam"
  [BG]="Bulgaria"
  [BF]="Burkina Faso"
  [BI]="Burundi"
  [CV]="Cabo Verde"
  [KH]="Cambodia"
  [CM]="Cameroon"
  [CA]="Canada"
  [KY]="Cayman Islands"
  [CF]="Central African Republic"
  [TD]="Chad"
  [CL]="Chile"
  [CN]="China"
  [CX]="Christmas Island"
  [CC]="Cocos (Keeling) Islands"
  [CO]="Colombia"
  [KM]="Comoros"
  [CG]="Congo"
  [CD]="Congo (Democratic Republic of the)"
  [CK]="Cook Islands"
  [CR]="Costa Rica"
  [CI]="Côte d'Ivoire"
  [HR]="Croatia"
  [CU]="Cuba"
  [CW]="Curaçao"
  [CY]="Cyprus"
  [CZ]="Czech Republic"
  [DK]="Denmark"
  [DJ]="Djibouti"
  [DM]="Dominica"
  [DO]="Dominican Republic"
  [EC]="Ecuador"
  [EG]="Egypt"
  [SV]="El Salvador"
  [GQ]="Equatorial Guinea"
  [ER]="Eritrea"
  [EE]="Estonia"
  [SZ]="Eswatini"
  [ET]="Ethiopia"
  [FK]="Falkland Islands (Malvinas)"
  [FO]="Faroe Islands"
  [FJ]="Fiji"
  [FI]="Finland"
  [FR]="France"
  [GF]="French Guiana"
  [PF]="French Polynesia"
  [TF]="French Southern Territories"
  [GA]="Gabon"
  [GM]="Gambia"
  [GE]="Georgia"
  [DE]="Germany"
  [GH]="Ghana"
  [GI]="Gibraltar"
  [GR]="Greece"
  [GL]="Greenland"
  [GD]="Grenada"
  [GP]="Guadeloupe"
  [GU]="Guam"
  [GT]="Guatemala"
  [GG]="Guernsey"
  [GN]="Guinea"
  [GW]="Guinea-Bissau"
  [GY]="Guyana"
  [HT]="Haiti"
  [HM]="Heard Island and McDonald Islands"
  [VA]="Holy See"
  [HN]="Honduras"
  [HK]="Hong Kong"
  [HU]="Hungary"
  [IS]="Iceland"
  [IN]="India"
  [ID]="Indonesia"
  [IR]="Iran"
  [IQ]="Iraq"
  [IE]="Ireland"
  [IM]="Isle of Man"
  [IL]="Israel"
  [IT]="Italy"
  [JM]="Jamaica"
  [JP]="Japan"
  [JE]="Jersey"
  [JO]="Jordan"
  [KZ]="Kazakhstan"
  [KE]="Kenya"
  [KI]="Kiribati"
  [KP]="Korea (Democratic People's Republic of)"
  [KR]="Korea (Republic of)"
  [KW]="Kuwait"
  [KG]="Kyrgyzstan"
  [LA]="Lao People's Democratic Republic"
  [LV]="Latvia"
  [LB]="Lebanon"
  [LS]="Lesotho"
  [LR]="Liberia"
  [LY]="Libya"
  [LI]="Liechtenstein"
  [LT]="Lithuania"
  [LU]="Luxembourg"
  [MO]="Macao"
  [MG]="Madagascar"
  [MW]="Malawi"
  [MY]="Malaysia"
  [MV]="Maldives"
  [ML]="Mali"
  [MT]="Malta"
  [MH]="Marshall Islands"
  [MQ]="Martinique"
  [MR]="Mauritania"
  [MU]="Mauritius"
  [YT]="Mayotte"
  [MX]="Mexico"
  [FM]="Micronesia (Federated States of)"
  [MD]="Moldova"
  [MC]="Monaco"
  [MN]="Mongolia"
  [ME]="Montenegro"
  [MS]="Montserrat"
  [MA]="Morocco"
  [MZ]="Mozambique"
  [MM]="Myanmar"
  [NA]="Namibia"
  [NR]="Nauru"
  [NP]="Nepal"
  [NL]="Netherlands"
  [NC]="New Caledonia"
  [NZ]="New Zealand"
  [NI]="Nicaragua"
  [NE]="Niger"
  [NG]="Nigeria"
  [NU]="Niue"
  [NF]="Norfolk Island"
  [MK]="North Macedonia"
  [MP]="Northern Mariana Islands"
  [NO]="Norway"
  [OM]="Oman"
  [PK]="Pakistan"
  [PW]="Palau"
  [PS]="Palestine"
  [PA]="Panama"
  [PG]="Papua New Guinea"
  [PY]="Paraguay"
  [PE]="Peru"
  [PH]="Philippines"
  [PN]="Pitcairn"
  [PL]="Poland"
  [PT]="Portugal"
  [PR]="Puerto Rico"
  [QA]="Qatar"
  [RE]="Réunion"
  [RO]="Romania"
  [RU]="Russia"
  [RW]="Rwanda"
  [BL]="Saint Barthélemy"
  [SH]="Saint Helena"
  [KN]="Saint Kitts and Nevis"
  [LC]="Saint Lucia"
  [MF]="Saint Martin (French part)"
  [PM]="Saint Pierre and Miquelon"
  [VC]="Saint Vincent and the Grenadines"
  [WS]="Samoa"
  [SM]="San Marino"
  [ST]="Sao Tome and Principe"
  [SA]="Saudi Arabia"
  [SN]="Senegal"
  [RS]="Serbia"
  [SC]="Seychelles"
  [SL]="Sierra Leone"
  [SG]="Singapore"
  [SX]="Sint Maarten (Dutch part)"
  [SK]="Slovakia"
  [SI]="Slovenia"
  [SB]="Solomon Islands"
  [SO]="Somalia"
  [ZA]="South Africa"
  [GS]="South Georgia and the South Sandwich Islands"
  [SS]="South Sudan"
  [ES]="Spain"
  [LK]="Sri Lanka"
  [SD]="Sudan"
  [SR]="Suriname"
  [SJ]="Svalbard and Jan Mayen"
  [SE]="Sweden"
  [CH]="Switzerland"
  [SY]="Syrian Arab Republic"
  [TW]="Taiwan"
  [TJ]="Tajikistan"
  [TZ]="Tanzania"
  [TH]="Thailand"
  [TL]="Timor-Leste"
  [TG]="Togo"
  [TK]="Tokelau"
  [TO]="Tonga"
  [TT]="Trinidad and Tobago"
  [TN]="Tunisia"
  [TR]="Turkey"
  [TM]="Turkmenistan"
  [TC]="Turks and Caicos Islands"
  [TV]="Tuvalu"
  [UG]="Uganda"
  [UA]="Ukraine"
  [AE]="United Arab Emirates"
  [GB]="United Kingdom"
  [US]="United States"
  [UM]="United States Minor Outlying Islands"
  [UY]="Uruguay"
  [UZ]="Uzbekistan"
  [VU]="Vanuatu"
  [VE]="Venezuela"
  [VN]="Vietnam"
  [VG]="Virgin Islands (British)"
  [VI]="Virgin Islands (U.S.)"
  [WF]="Wallis and Futuna"
  [EH]="Western Sahara"
  [YE]="Yemen"
  [ZM]="Zambia"
  [ZW]="Zimbabwe"
  [XK]="Kosovo"
  [EU]="European Union"
  [WW]="Worldwide"
)

declare -A PRIMARY_SERVICES=(
  [MAXMIND]="maxmind.com|geoip.maxmind.com|/geoip/v2.1/city/me"
  [RIPE]="rdap.db.ripe.net|rdap.db.ripe.net|/ip/{ip}"
  [IPINFO_IO]="ipinfo.io|ipinfo.io|/widget/demo/{ip}"
  [IPREGISTRY]="ipregistry.co|api.ipregistry.co|/{ip}?hostname=true&key=sb69ksjcajfs4c"
  [IPAPI_CO]="ipapi.co|ipapi.co|/{ip}/json"
  [CLOUDFLARE]="cloudflare.com|www.cloudflare.com|/cdn-cgi/trace"
  [IPLOCATION_COM]="iplocation.com|iplocation.com"
  [COUNTRY_IS]="country.is|api.country.is|/{ip}"
  [GEOAPIFY_COM]="geoapify.com|api.geoapify.com|/v1/ipinfo?&ip={ip}&apiKey=b8568cb9afc64fad861a69edbddb2658"
  [GEOJS_IO]="geojs.io|get.geojs.io|/v1/ip/country.json?ip={ip}"
  [IPAPI_IS]="ipapi.is|api.ipapi.is|/?q={ip}"
  [IPBASE_COM]="ipbase.com|api.ipbase.com|/v2/info?ip={ip}"
  [IPQUERY_IO]="ipquery.io|api.ipquery.io|/{ip}"
  [IPWHO_IS]="ipwho.is|ipwho.is|/{ip}"
  [IPAPI_COM]="ip-api.com|demo.ip-api.com|/json/{ip}?fields=countryCode"
  [2IP]="2ip.io|api.2ip.io"
)

PRIMARY_SERVICES_ORDER=(
  "MAXMIND"
  "RIPE"
  "IPINFO_IO"
  "CLOUDFLARE"
  "IPREGISTRY"
  "IPAPI_CO"
  "IPLOCATION_COM"
  "COUNTRY_IS"
  "GEOAPIFY_COM"
  "GEOJS_IO"
  "IPAPI_IS"
  "IPBASE_COM"
  "IPQUERY_IO"
  "IPWHO_IS"
  "IPAPI_COM"
  "2IP"
)

declare -A PRIMARY_SERVICES_CUSTOM_HANDLERS=(
  [CLOUDFLARE]="lookup_cloudflare"
  [IPLOCATION_COM]="lookup_iplocation_com"
  [2IP]="lookup_2ip"
)

declare -A SERVICE_HEADERS=(
  [IPREGISTRY]="Origin: https://ipregistry.co"
  [MAXMIND]="Referer: https://www.maxmind.com"
  [IPAPI_COM]="Origin: https://ip-api.com"
)

declare -A CUSTOM_SERVICES=(
  [GOOGLE]="Google"
  [GOOGLE_SEARCH_CAPTCHA]="Google Search Captcha"
  [YOUTUBE]="YouTube"
  [YOUTUBE_PREMIUM]="YouTube Premium"
  [YOUTUBE_MUSIC]="YouTube Music"
  [TWITCH]="Twitch"
  [CHATGPT]="ChatGPT"
  [CHATGPT_ACCESS]="ChatGPT Access"
  [CLAUDE_ACCESS]="Claude Access"
  [GEMINI_ACCESS]="Gemini Access"
  [COPILOT_ACCESS]="Copilot Access"
  [GROK_ACCESS]="Grok Access"
  [NETFLIX]="Netflix"
  [NETFLIX_CATALOG]="Netflix Catalog"
  [DISNEY_PLUS]="Disney+"
  [SPOTIFY]="Spotify"
  [SPOTIFY_SIGNUP]="Spotify Signup"
  [DEEZER]="Deezer"
  [REDDIT]="Reddit"
  [REDDIT_GUEST_ACCESS]="Reddit (Guest Access)"
  [AMAZON_PRIME]="Amazon Prime"
  [APPLE]="Apple"
  [STEAM]="Steam"
  [PLAYSTATION]="PlayStation"
  [TIKTOK]="TikTok"
  [OOKLA_SPEEDTEST]="Ookla Speedtest"
  [JETBRAINS]="JetBrains"
  [BING]="Microsoft (Bing)"
)

# Popular services in blocks: "Title|SERVICE SERVICE ...". The order of checks and of the table
# comes from here, the titles are printed above each block
CUSTOM_SECTIONS=(
  "Google and YouTube|GOOGLE GOOGLE_SEARCH_CAPTCHA YOUTUBE YOUTUBE_PREMIUM YOUTUBE_MUSIC"
  "AI assistants|CHATGPT CHATGPT_ACCESS CLAUDE_ACCESS GEMINI_ACCESS COPILOT_ACCESS GROK_ACCESS"
  "Video|NETFLIX NETFLIX_CATALOG DISNEY_PLUS AMAZON_PRIME TWITCH TIKTOK"
  "Music|SPOTIFY SPOTIFY_SIGNUP DEEZER"
  "Social|REDDIT REDDIT_GUEST_ACCESS"
  "Other|APPLE STEAM PLAYSTATION OOKLA_SPEEDTEST JETBRAINS BING"
)

CUSTOM_SERVICES_ORDER=()
declare -A CUSTOM_SECTION_OF=() # display name -> block title
for _section in "${CUSTOM_SECTIONS[@]}"; do
  for _service in ${_section#*|}; do
    CUSTOM_SERVICES_ORDER+=("$_service")
    CUSTOM_SECTION_OF["${CUSTOM_SERVICES[$_service]}"]="${_section%%|*}"
  done
done
unset _section _service

declare -A CUSTOM_SERVICES_HANDLERS=(
  [GOOGLE]="lookup_google"
  [GOOGLE_SEARCH_CAPTCHA]="lookup_google_search_captcha"
  [YOUTUBE]="lookup_youtube"
  [YOUTUBE_PREMIUM]="lookup_youtube_premium"
  [YOUTUBE_MUSIC]="lookup_youtube_music"
  [TWITCH]="lookup_twitch"
  [CHATGPT]="lookup_chatgpt"
  [CHATGPT_ACCESS]="lookup_chatgpt_access"
  [CLAUDE_ACCESS]="lookup_claude_access"
  [GEMINI_ACCESS]="lookup_gemini_access"
  [COPILOT_ACCESS]="lookup_copilot_access"
  [GROK_ACCESS]="lookup_grok_access"
  [NETFLIX]="lookup_netflix"
  [NETFLIX_CATALOG]="lookup_netflix_catalog"
  [DISNEY_PLUS]="lookup_disney_plus"
  [SPOTIFY]="lookup_spotify"
  [SPOTIFY_SIGNUP]="lookup_spotify_signup"
  [DEEZER]="lookup_deezer"
  [REDDIT]="lookup_reddit"
  [REDDIT_GUEST_ACCESS]="lookup_reddit_guest_access"
  [AMAZON_PRIME]="lookup_amazon_prime"
  [APPLE]="lookup_apple"
  [STEAM]="lookup_steam"
  [PLAYSTATION]="lookup_playstation"
  [TIKTOK]="lookup_tiktok"
  [YOUTUBE_CDN]="lookup_youtube_cdn"
  [NETFLIX_CDN]="lookup_netflix_cdn"
  [OOKLA_SPEEDTEST]="lookup_ookla_speedtest"
  [JETBRAINS]="lookup_jetbrains"
  [BING]="lookup_bing"
  [IPINFO_NETWORK]="lookup_ipinfo_network"
  [IPAPI_HOSTING]="lookup_ipapi_hosting"
  [PROXYCHECK]="lookup_proxycheck"
  [DNS_RESOLVER]="lookup_dns_resolver"
)

declare -A CDN_SERVICES=(
  [YOUTUBE_CDN]="YouTube CDN"
  [NETFLIX_CDN]="Netflix CDN"
)

CDN_SERVICES_ORDER=(
  "YOUTUBE_CDN"
  "NETFLIX_CDN"
)

# How the IP itself is seen: hosting, VPN or proxy flags and the DNS resolver in use
declare -A NETWORK_SERVICES=(
  [IPINFO_NETWORK]="Network (ipinfo)"
  [IPAPI_HOSTING]="Hosting (ip-api)"
  [PROXYCHECK]="VPN/Proxy (proxycheck)"
  [DNS_RESOLVER]="DNS resolver"
)

NETWORK_SERVICES_ORDER=(
  "IPINFO_NETWORK"
  "IPAPI_HOSTING"
  "PROXYCHECK"
  "DNS_RESOLVER"
)

declare -A SERVICE_GROUPS=(
  [primary]="${PRIMARY_SERVICES_ORDER[*]}"
  [custom]="${CUSTOM_SERVICES_ORDER[*]}"
  [cdn]="${CDN_SERVICES_ORDER[*]}"
  [network]="${NETWORK_SERVICES_ORDER[*]}"
)

EXCLUDED_SERVICES=(
  # "IPINFO_IO"
  # "IPREGISTRY"
  "IPAPI_CO" # answers 429 RateLimited to datacenter IPs
)

IDENTITY_SERVICES=(
  "ident.me"
  "ifconfig.me"
  "api64.ipify.org"
  "icanhazip.com"
)

# Services asked about the IPv6 address over IPv4. Empty since ipinfo.io moved to ipinfo_widget,
# which asks v6.ipinfo.io over IPv6 instead
IPV6_OVER_IPV4_SERVICES=()

color() {
  local color_name="$1"
  local text="$2"
  local code

  case "$color_name" in
    HEADER) code="$COLOR_HEADER" ;;
    SERVICE) code="$COLOR_SERVICE" ;;
    HEART) code="$COLOR_HEART" ;;
    URL) code="$COLOR_URL" ;;
    ASN) code="$COLOR_ASN" ;;
    TABLE_HEADER) code="$COLOR_TABLE_HEADER" ;;
    TABLE_VALUE) code="$COLOR_TABLE_VALUE" ;;
    NULL) code="$COLOR_NULL" ;;
    ERROR) code="$COLOR_ERROR" ;;
    WARN) code="$COLOR_WARN" ;;
    INFO) code="$COLOR_INFO" ;;
    RESET) code="$COLOR_RESET" ;;
    *) code="$color_name" ;;
  esac

  if [[ "$INTERACTIVE" == true ]]; then
    printf "\033[%sm%s\033[0m" "$code" "$text"
  else
    printf "%s" "$text"
  fi
}

bold() {
  local text="$1"
  if [[ "$INTERACTIVE" == true ]]; then
    printf "\033[1m%s\033[0m" "$text"
  else
    printf "%s" "$text"
  fi
}

get_timestamp() {
  local format="$1"
  date +"$format"
}

log() {
  local log_level="$1"
  local message="${*:2}"
  local timestamp

  if [[ "$VERBOSE" == true ]]; then
    local color_code

    timestamp=$(get_timestamp "%d.%m.%Y %H:%M:%S")

    case "$log_level" in
      "$LOG_ERROR") color_code=ERROR ;;
      "$LOG_WARN") color_code=WARN ;;
      "$LOG_INFO") color_code=INFO ;;
      *) color_code=RESET ;;
    esac

    printf "[%s] [%s]: %s\n" "$timestamp" "$(color $color_code "$log_level")" "$message" >&2
  fi
}

error_exit() {
  local message="$1"
  local exit_code="${2:-1}"
  printf "%s %s\n" "$(color ERROR '[ERROR]')" "$(color TABLE_HEADER "$message")" >&2
  # Справку показываем только при ошибке в аргументах
  case "$message" in
    "Unknown option"* | "Invalid"* | "Unknown"*) display_help ;;
  esac
  exit "$exit_code"
}

display_help() {
  cat <<EOF

ipregion-lucx $LUCX_VERSION — в какой стране видят этот IP (GeoIP-сервисы, сайты, флаги VPN/хостинг)

Как пользоваться (достаточно этих трёх):
  ./ipregion-lucx.sh                  проверить IP этой машины (все сервисы, ~1 минута)
  ./ipregion-lucx.sh 1.2.3.4          проверить ЧУЖОЙ IP (до покупки, до rebind-ip), ничего не запуская на нём
  ./ipregion-lucx.sh --expect RU      то же, но сверить со страной: код выхода 0 = ок, 3 = не совпало

Дополнительно:
  -g, --group ГРУППА   только одна группа: primary (GeoIP), custom (сайты), cdn, network (VPN/хостинг)
  -e, --expect СТРАНА  ожидаемая страна (RU, EE, FI ...): в конце «ок» или «НЕ СОВПАДАЕТ», код выхода 3
  -j, --json           вывод JSON (для скриптов и сводных таблиц)
  -4, --ipv4 / -6, --ipv6   только IPv4 / только IPv6
  -p, --proxy host:port     проверять через SOCKS5-прокси (так можно смотреть IP, который видят клиенты)
  -i, --interface IF   использовать сетевой интерфейс
  -t, --timeout СЕК    таймаут запроса (по умолчанию $CURL_TIMEOUT)
  -P, --parallel N     сколько сервисов проверять одновременно (по умолчанию $PARALLEL_JOBS, 1 = по одному)
      --no-doh         не проверять DoH-резолверы (быстрее, если DNS в порядке)
      --mask           скрыть последние два октета IP в шапке (для скриншотов)
  -v, --verbose        подробный лог
  -h, --help           эта справка

Примеры:
  ./ipregion-lucx.sh -g primary -4 --expect EE         быстрая проверка ноды: страна по GeoIP
  ./ipregion-lucx.sh 185.113.138.230 --expect EE       проверить IP с другого сервера
  ./ipregion-lucx.sh -j -g primary | jq .              результат для разбора скриптом

Для чужого IP проверяются только GeoIP-сервисы и флаги VPN/хостинг: сайты (YouTube, Netflix ...)
смотрят на само соединение, их можно проверить только с самой ноды или через -p.

EOF
}

is_installed() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1
}

check_missing_dependencies() {
  local missing_pkgs=()
  local cmd

  for pkg in "${DEPENDENCIES[@]}"; do
    cmd="${DEPENDENCY_COMMANDS[$pkg]:-$pkg}"
    if ! is_installed "$cmd"; then
      missing_pkgs+=("$pkg")
    fi
  done

  echo "${missing_pkgs[@]}"
}

prompt_for_installation() {
  local command="$1"
  local missing_pkgs=("${@:2}")
  local answer

  echo "Missing dependencies: ${missing_pkgs[*]}"
  echo "Will run: $command"
  read -r -p "Install now? [y/N]: " answer

  case "${answer,,}" in
    y | yes)
      return 0
      ;;
    *)
      echo "Nothing installed. To install manually: $command"
      exit 0
      ;;
  esac
}

# Package names to install for the missing dependencies
resolve_packages() {
  local pkg_manager="$1"
  local pkg
  shift

  for pkg in "$@"; do
    if [[ "$pkg_manager" == "apt" && "$pkg" == "util-linux" ]]; then
      # util-linux is always installed on Debian/Ubuntu, column comes from
      # bsdextrautils (Debian 11+, Ubuntu 21.04+) or bsdmainutils on older releases
      if apt-cache show bsdextrautils >/dev/null 2>&1; then
        echo "bsdextrautils"
      else
        echo "bsdmainutils"
      fi
    else
      echo "$pkg"
    fi
  done
}

# The same commands install_with_package_manager runs, shown before asking
describe_install_command() {
  local pkg_manager="$1"
  local packages="${*:2}"
  local sudo_prefix=""

  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    sudo_prefix="sudo "
  fi

  case "$pkg_manager" in
    apt) echo "${sudo_prefix}apt update && ${sudo_prefix}apt install -y $packages" ;;
    pacman) echo "${sudo_prefix}pacman -S --needed --noconfirm $packages" ;;
    dnf) echo "${sudo_prefix}dnf install -y $packages" ;;
    termux) echo "apt update && apt install -y $packages" ;;
  esac
}

get_package_manager() {
  # Check if the script is running in Termux
  if [[ -d /data/data/com.termux ]]; then
    echo "termux"
    return
  fi

  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    case "$ID" in
      debian | ubuntu)
        echo "apt"
        ;;
      arch)
        echo "pacman"
        ;;
      fedora)
        echo "dnf"
        ;;
      *)
        error_exit "Unknown distribution: $ID. Please install dependencies manually."
        ;;
    esac
  else
    error_exit "File /etc/os-release not found, unable to determine distribution. Please install dependencies manually."
  fi
}

install_with_package_manager() {
  local pkg_manager="$1"
  local packages=("${@:2}")
  local use_sudo=""

  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    use_sudo="sudo"
    log "$LOG_INFO" "Running as non-root user, using sudo"
  fi

  case "$pkg_manager" in
    *apt)
      # NEEDRESTART_MODE is left at its default so services are never restarted silently
      $use_sudo "$pkg_manager" update
      $use_sudo "$pkg_manager" install -y "${packages[@]}"
      ;;
    *pacman)
      # No -y: refreshing the database without -u is a partial upgrade
      if ! $use_sudo "$pkg_manager" -S --needed --noconfirm "${packages[@]}"; then
        error_exit "pacman could not install ${packages[*]}. Run 'pacman -Syu' first, then start the script again."
      fi
      ;;
    *dnf)
      $use_sudo "$pkg_manager" install -y "${packages[@]}"
      ;;
    termux)
      apt update
      apt install -y "${packages[@]}"
      ;;
    *)
      error_exit "Unknown package manager: $pkg_manager"
      ;;
  esac
}

install_dependencies() {
  local missing_packages packages
  local pkg_manager command

  log "$LOG_INFO" "Checking for dependencies"
  read -r -a missing_packages <<<"$(check_missing_dependencies)"

  if [[ ${#missing_packages[@]} -eq 0 ]]; then
    log "$LOG_INFO" "All dependencies are installed"
    return 0
  fi

  pkg_manager=$(get_package_manager) || exit 1
  log "$LOG_INFO" "Detected package manager: $pkg_manager"

  read -r -a packages <<<"$(resolve_packages "$pkg_manager" "${missing_packages[@]}" | tr '\n' ' ')"
  command=$(describe_install_command "$pkg_manager" "${packages[@]}")

  # Without a terminal (ssh host 'bash -s', cron) the redirect fails and the prompt
  # never runs: stop instead of installing packages unasked
  if ! prompt_for_installation "$command" "${missing_packages[@]}" </dev/tty; then
    error_exit "Missing dependencies: ${missing_packages[*]}. No terminal to ask, install them manually: $command"
  fi

  log "$LOG_INFO" "Installing missing dependencies"
  install_with_package_manager "$pkg_manager" "${packages[@]}"
}

is_valid_json() {
  local json="$1"
  jq -e . >/dev/null 2>&1 <<<"$json"
}

process_json() {
  local json="$1"
  local jq_filter="$2"
  jq -r "$jq_filter" <<<"$json"
}

format_value() {
  local value="$1"
  local not_available="$2"

  if [[ "$value" == "$not_available" ]]; then
    color NULL "$value"
  else
    bold "$value"
  fi
}

print_value_or_colored() {
  local value="$1"
  local color_name="$2"

  if [[ "$JSON_OUTPUT" == true ]]; then
    echo "$value"
    return
  fi

  color "$color_name" "$value"
}

mask_ipv4() {
  local ip="$1"
  echo "${ip%.*.*}.*.*"
}

mask_ipv6() {
  local ip="$1"
  echo "$ip" | awk -F: '{
    for(i=1;i<=NF;i++) if($i=="") $i="0";
    while(NF<8) for(i=1;i<=8;i++) if($i=="0"){NF++; break;}
    printf "%s:%s:%s::\n", $1, $2, $3
  }'
}

is_ip_address() {
  local ip="$1" octet
  if [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    for octet in "${BASH_REMATCH[@]:1}"; do
      ((10#$octet <= 255)) || return 1
    done
    return 0
  fi
  [[ "$ip" == *:* && "$ip" =~ ^[0-9a-fA-F:]+$ ]]
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h | --help)
        display_help
        exit 0
        ;;
      -v | --verbose)
        VERBOSE=true
        shift
        ;;
      -j | --json)
        JSON_OUTPUT=true
        shift
        ;;
      -g | --group)
        GROUPS_TO_SHOW="$2"
        shift 2
        ;;
      -t | --timeout)
        if [[ "$2" =~ ^[0-9]+$ ]]; then
          CURL_TIMEOUT="$2"
        else
          error_exit "Invalid timeout value: $2. Timeout must be a positive integer"
        fi
        shift 2
        ;;
      -4 | --ipv4)
        IPV4_ONLY=true
        shift
        ;;
      -6 | --ipv6)
        if ! check_ip_support 6; then
          error_exit "IPv6 is not supported on this system"
        fi

        IPV6_ONLY=true
        shift
        ;;
      -p | --proxy)
        PROXY_ADDR="$2"
        log "$LOG_INFO" "Using SOCKS5 proxy: $PROXY_ADDR"
        shift 2
        ;;
      -i | --interface)
        INTERFACE_NAME="$2"
        log "$LOG_INFO" "Using interface: $INTERFACE_NAME"
        shift 2
        ;;
      -P | --parallel)
        if [[ "$2" =~ ^[1-9][0-9]*$ ]]; then
          PARALLEL_JOBS="$2"
        else
          error_exit "Invalid parallel value: $2. It must be a positive integer"
        fi
        shift 2
        ;;
      --no-update-check)
        UPDATE_CHECK=false
        shift
        ;;
      --no-doh)
        USE_DOH=false
        shift
        ;;
      --mask)
        MASK_IP=true
        shift
        ;;
      -e | --expect)
        if [[ "$2" =~ ^[A-Za-z]{2}$ ]]; then
          EXPECT_CC="${2^^}"
        else
          error_exit "Invalid country code: ${2:-<empty>}. Use two letters, e.g. RU or EE"
        fi
        shift 2
        ;;
      *)
        if is_ip_address "$1" && [[ -z "$TARGET_IP" ]]; then
          TARGET_IP="$1"
          shift
        else
          error_exit "Unknown option: $1"
        fi
        ;;
    esac
  done
}

check_ip_support() {
  local version="$1"
  log "$LOG_INFO" "Checking for IPv${version} support"

  if ip "-${version}" addr show scope global 2>/dev/null | grep -q "inet${version//4/ }"; then
    log "$LOG_INFO" "IPv${version} is supported"
    return 0
  fi

  log "$LOG_WARN" "IPv${version} is not supported on this system"
  return 1
}

get_external_ip() {
  local ip
  local counts
  declare -A counts

  if [[ "$IPV4_ONLY" == true ]] || [[ "$IPV6_ONLY" != true ]]; then
    log "$LOG_INFO" "Checking external IPv4 addresses"
    for service in "${IDENTITY_SERVICES[@]}"; do
      ip="$(make_request GET "https://$service" --ip-version 4 2>/dev/null)"
      if [[ -n "$ip" ]]; then
        counts[$ip]=$(( ${counts[$ip]:-0} + 1 ))
        log "$LOG_INFO" "[$service] IPv4: $ip"
      fi
    done

    EXTERNAL_IPV4=""
    for ip in "${!counts[@]}"; do
      if [[ ${counts[$ip]} -ge 2 ]]; then
        EXTERNAL_IPV4="$ip"
        log "$LOG_INFO" "Confirmed external IPv4: $EXTERNAL_IPV4"
        break
      fi
    done

    # Fallback, если совпадений нет
    if [[ -z "$EXTERNAL_IPV4" ]]; then
      for ip in "${!counts[@]}"; do
        EXTERNAL_IPV4="$ip"
        log "$LOG_INFO" "Fallback external IPv4: $EXTERNAL_IPV4"
        break
      done
    fi
  fi

  unset counts
  declare -A counts
  if [[ "$IPV6_ONLY" == true ]] || { [[ "$IPV6_SUPPORTED" -eq 0 ]] && [[ "$IPV4_ONLY" != true ]]; }; then
    log "$LOG_INFO" "Checking external IPv6 addresses"
    for service in "${IDENTITY_SERVICES[@]}"; do
      ip="$(make_request GET "https://$service" --ip-version 6 2>/dev/null)"
      if [[ -n "$ip" ]]; then
        counts[$ip]=$(( ${counts[$ip]:-0} + 1 ))
        log "$LOG_INFO" "[$service] IPv6: $ip"
      fi
    done

    EXTERNAL_IPV6=""
    for ip in "${!counts[@]}"; do
      if [[ ${counts[$ip]} -ge 2 ]]; then
        EXTERNAL_IPV6="$ip"
        log "$LOG_INFO" "Confirmed external IPv6: $EXTERNAL_IPV6"
        break
      fi
    done

    if [[ -z "$EXTERNAL_IPV6" ]]; then
      for ip in "${!counts[@]}"; do
        EXTERNAL_IPV6="$ip"
        log "$LOG_INFO" "Fallback external IPv6: $EXTERNAL_IPV6"
        break
      done
    fi
  fi
}

get_asn() {
  local ip ip_version response

  if [[ -n "$EXTERNAL_IPV4" ]]; then
    ip="$EXTERNAL_IPV4"
    ip_version=4
  else
    ip="$EXTERNAL_IPV6"
    ip_version=6
  fi

  log "$LOG_INFO" "Getting ASN info for IP $ip"

  response=$(make_request GET "https://ipinfo.check.place/$ip" --ip-version "$ip_version" 2>/dev/null)
  asn=$(process_json "$response" ".ASN.AutonomousSystemNumber")
  asn_name=$(process_json "$response" ".ASN.AutonomousSystemOrganization")

  if [[ -z "$asn" || "$asn" == "null" || -z "$asn_name" || "$asn_name" == "null" ]]; then
    log "$LOG_INFO" "Primary source failed, trying backup source"
    response=$(make_request GET "https://geoip.oxl.app/api/ip/$ip" --ip-version "$ip_version")
    asn=$(process_json "$response" ".asn")
    asn_name=$(process_json "$response" ".organization.name")
    asn_name=${asn_name#null}
    log "$LOG_INFO" "ASN info (backup source): AS$asn $asn_name"
  else
    log "$LOG_INFO" "ASN info (primary source): AS$asn $asn_name"
  fi
}

get_iata_location() {
  local iata_code="$1"
  local url="https://www.air-port-codes.com/api/v1/single"
  local payload="iata=$iata_code"
  local apc_auth="96dc04b3fb"
  local referer="https://www.air-port-codes.com/"
  local response

  response=$(make_request POST "$url" \
    --header "APC-Auth: $apc_auth" \
    --header "Referer: $referer" \
    --data "$payload" \
    --ip-version 4)

  process_json "$response" ".airport.country.iso"
}

is_ipv6_over_ipv4_service() {
  local service="$1"
  for s in "${IPV6_OVER_IPV4_SERVICES[@]}"; do
    [[ "$s" == "$service" ]] && return 0
  done
  return 1
}

spinner_start() {
  local delay=0.1
  # shellcheck disable=SC1003
  local spinstr='|/-\\'
  local current_service

  spinner_running=true

  (
    while $spinner_running; do
      for ((i = 0; i < ${#spinstr}; i++)); do
        current_service=""

        if [[ -f "$SPINNER_SERVICE_FILE" ]]; then
          current_service="$(cat "$SPINNER_SERVICE_FILE")"
        fi

        printf "\r\033[K%s %s %s" \
          "$(color HEADER "${spinstr:$i:1}")" \
          "$(color HEADER "Checking:")" \
          "$(color SERVICE "$current_service")"

        sleep $delay
      done
    done
  ) &

  spinner_pid=$!
}

spinner_stop() {
  spinner_running=false

  if [[ -n "$spinner_pid" ]]; then
    kill "$spinner_pid" 2>/dev/null
    wait "$spinner_pid" 2>/dev/null
    spinner_pid=""
    printf "\\r%*s\\r" 40 " "
  fi

  if [[ -f "$SPINNER_SERVICE_FILE" ]]; then
    rm -f "$SPINNER_SERVICE_FILE"
    unset SPINNER_SERVICE_FILE
  fi
}

make_request() {
  local method="$1"
  local url="$2"
  shift 2
  local ip_version user_agent json data headers response_with_code response http_code
  local curl_args=(
    --silent --compressed
    --retry-connrefused --retry-all-errors
    --retry "$CURL_RETRIES"
    --connect-timeout "$CURL_TIMEOUT"
    --max-time "$CURL_TIMEOUT"
    -w '\n%{http_code}'
  )

  if [[ "$method" == "HEAD" ]]; then
    curl_args+=(--head)
  else
    curl_args+=(--request "$method")
  fi

  # --with-status: print the body and the HTTP code on the last line, 403/429 included
  # --system-dns: resolve with the system (or proxy) resolver, not with the DoH one
  local with_status=false
  local system_dns=false
  local doh_args=()

  while (($#)); do
    case "$1" in
      --ip-version)
        ip_version="$2"
        shift 2
        ;;
      --follow)
        curl_args+=(--location)
        shift
        ;;
      --with-status)
        with_status=true
        shift
        ;;
      --system-dns)
        system_dns=true
        shift
        ;;
      --user-agent)
        user_agent="$2"
        shift 2
        ;;
      --header)
        headers+=("$2")
        shift 2
        ;;
      --json)
        json="$2"
        shift 2
        ;;
      --data)
        data="$2"
        shift 2
        ;;
    esac
  done

  if [[ "$ip_version" == "4" ]]; then
    curl_args+=(-4)
  elif [[ "$ip_version" == "6" ]]; then
    curl_args+=(-6)
  fi

  for h in "${headers[@]}"; do
    curl_args+=(-H "$h")
  done

  if [[ -n "$user_agent" ]]; then
    curl_args+=(-A "$user_agent")
  fi

  if [[ -n "$json" ]]; then
    curl_args+=(--data "$json")
    curl_args+=(-H 'Content-Type: application/json')
  fi

  if [[ -n "$data" ]]; then
    curl_args+=(--data "$data")
    curl_args+=(-H 'Content-Type: application/x-www-form-urlencoded')
  fi

  # socks5h: hostnames are resolved by the proxy, so DNS does not leak past it
  if [[ -n "$PROXY_ADDR" ]]; then
    curl_args+=(--proxy "socks5h://$PROXY_ADDR")
  fi

  if [[ -n "$INTERFACE_NAME" ]]; then
    curl_args+=(--interface "$INTERFACE_NAME")
  fi

  curl_args+=("$url")

  if [[ "$system_dns" != true ]]; then
    doh_args=("${SELECTED_DOH_ARGS[@]}")
  fi

  response_with_code=$(timeout "$CURL_TIMEOUT"s curl "${curl_args[@]}" "${doh_args[@]}")
  local exit_status=$?

  http_code=$(tail -n1 <<<"$response_with_code")

  # run_lookup reads this log to explain an empty result (Blocked, RateLimited, Timeout)
  if [[ -n "${STATUS_LOG:-}" ]]; then
    if [[ $exit_status -eq 124 || $exit_status -eq 28 ]]; then
      echo "timeout" >>"$STATUS_LOG"
    else
      echo "$http_code" >>"$STATUS_LOG"
    fi
  fi

  if [[ $exit_status -eq 124 ]]; then
    echo ""
    return 0
  fi

  if [[ "$with_status" == true ]]; then
    echo "$response_with_code"
    return 0
  fi

  response=$(sed '$d' <<<"$response_with_code")

  if [[ "$http_code" == "403" || "$http_code" == "429" ]]; then
    echo ""
    return 0
  fi

  echo "$response"
}

service_build_request() {
  local service="$1" ip="$2" ip_version="$3"
  local cfg="${PRIMARY_SERVICES[$service]}"
  local display_name domain url_template url headers_str response_format

  IFS='|' read -r display_name domain url_template response_format <<<"$cfg"

  if [[ -z "$display_name" ]]; then
    display_name="$service"
  fi

  url="https://$domain${url_template//\{ip\}/$ip}"

  if [[ -n "${SERVICE_HEADERS[$service]}" ]]; then
    headers_str="${SERVICE_HEADERS[$service]}"
  fi

  printf "%s\n%s\n%s\n%s" "$display_name" "$url" "${response_format:-json}" "$headers_str"
}

probe_service() {
  local service="$1"
  local ip_version="$2"
  local ip="$3"
  local built display_name url response_format headers_line request_params response

  mapfile -t built < <(service_build_request "$service" "$ip" "$ip_version")
  display_name="${built[0]}"
  url="${built[1]}"
  response_format="${built[2]}"
  headers_line="${built[3]}"

  if [[ -n "$headers_line" ]]; then
    IFS='||' read -ra hs <<<"$headers_line"
    for h in "${hs[@]}"; do
      if [[ -n "$h" ]]; then
        request_params+=(--header "$h")
      fi
    done
  fi

  if [[ "$service" == "IPINFO_IO" ]]; then
    # One answer shared with the "Network (ipinfo)" row: ipinfo.io rate-limits repeated requests
    response=$(ipinfo_widget "$ip_version")
  else
    if [[ "$ip_version" == "6" ]] && is_ipv6_over_ipv4_service "$service"; then
      ip_version="4"
    fi

    response=$(make_request GET "$url" "${request_params[@]}" --ip-version "$ip_version")
  fi

  process_response "$service" "$response" "$display_name" "$response_format"
}

process_response() {
  local service="$1"
  local response="$2"
  local display_name="$3"
  local response_format="${4:-json}"
  local jq_filter

  if [[ -z "$response" || "$response" == *"<html"* ]]; then
    echo "N/A"
    return
  fi

  if [[ "$response_format" == "plain" ]]; then
    echo "$response" | tr -d '\r\n '
    return
  fi

  if ! is_valid_json "$response"; then
    log "$LOG_ERROR" "Invalid JSON response from $display_name: $response"
    return 1
  fi

  case "$service" in
    MAXMIND)
      jq_filter='.country.iso_code'
      ;;
    RIPE)
      jq_filter='.country'
      ;;
    IPINFO_IO)
      jq_filter='.data.country'
      ;;
    IPREGISTRY)
      jq_filter='.location.country.code'
      ;;
    IPAPI_CO)
      jq_filter='.country'
      ;;
    COUNTRY_IS)
      jq_filter='.country'
      ;;
    GEOAPIFY_COM)
      jq_filter='.country.iso_code'
      ;;
    GEOJS_IO)
      jq_filter='.[0].country'
      ;;
    IPAPI_IS)
      # The free tier now returns only the country name ("The Netherlands")
      jq_filter='.location.country_code // .country'
      ;;
    IPBASE_COM)
      jq_filter='.data.location.country.alpha2'
      ;;
    IPQUERY_IO)
      jq_filter='.location.country_code'
      ;;
    IPWHO_IS)
      jq_filter='.country_code'
      ;;
    IPAPI_COM)
      jq_filter='.countryCode'
      ;;
    *)
      echo "$response"
      ;;
  esac

  local value
  value=$(process_json "$response" "$jq_filter")

  if [[ "$service" == "IPAPI_IS" && ${#value} -gt 2 && "$value" != "null" ]]; then
    value=$(country_code_by_name "$value")
  fi

  echo "$value"
}

country_code_by_name() {
  local name="${1,,}"
  local code

  name="${name#the }"

  for code in "${!COUNTRY_NAMES[@]}"; do
    if [[ "${COUNTRY_NAMES[$code],,}" == "$name" ]]; then
      echo "$code"
      return
    fi
  done
}

set_spinner_text() {
  if [[ -n "${SPINNER_SERVICE_FILE:-}" ]]; then
    echo "$1" >"$SPINNER_SERVICE_FILE"
  fi
}

# Runs one lookup with its own status log. An empty result is replaced by the reason
# taken from the HTTP statuses of its requests: Blocked (403), RateLimited (429), Timeout
run_lookup() {
  local log result reason color_name

  log=$(mktemp "$WORK_DIR/status.XXXXXX")
  result=$(STATUS_LOG="$log" "$@")

  if [[ -z "$result" || "$result" == "null" || "$result" == "N/A" ]]; then
    if grep -qx "429" "$log"; then
      reason="RateLimited"
      color_name="NULL"
    elif grep -qx "403" "$log"; then
      reason="Blocked"
      color_name="HEART"
    elif grep -qx "timeout" "$log"; then
      reason="Timeout"
      color_name="NULL"
    fi

    if [[ -n "$reason" ]]; then
      result=$(print_value_or_colored "$reason" "$color_name")
    fi
  fi

  rm -f "$log"
  echo "$result"
}

# True when this service should also be checked over IPv6
ipv6_check_enabled() {
  [[ "$IPV4_ONLY" != true && "$IPV6_SUPPORTED" -eq 0 && -n "$EXTERNAL_IPV6" ]]
}

process_service() {
  local service="$1"
  local service_config="${PRIMARY_SERVICES[$service]}"
  local display_name domain url_template response_format ipv4_result ipv6_result handler_func

  IFS='|' read -r display_name domain url_template response_format <<<"$service_config"

  if [[ -z "$display_name" ]]; then
    display_name="$service"
  fi

  set_spinner_text "$display_name"

  if [[ -n "${PRIMARY_SERVICES_CUSTOM_HANDLERS[$service]}" ]]; then
    handler_func="${PRIMARY_SERVICES_CUSTOM_HANDLERS[$service]}"

    if [[ "$IPV6_ONLY" != true ]]; then
      log "$LOG_INFO" "Checking $display_name via IPv4 (custom handler)"
      ipv4_result=$(run_lookup "$handler_func" 4)
    fi

    if ipv6_check_enabled; then
      log "$LOG_INFO" "Checking $display_name via IPv6 (custom handler)"
      ipv6_result=$(run_lookup "$handler_func" 6)
    fi
  else
    if [[ "$IPV6_ONLY" != true && -n "$EXTERNAL_IPV4" ]]; then
      log "$LOG_INFO" "Checking $display_name via IPv4"
      ipv4_result=$(run_lookup probe_service "$service" 4 "$EXTERNAL_IPV4")
    fi

    if ipv6_check_enabled; then
      if is_ipv6_over_ipv4_service "$service"; then
        log "$LOG_INFO" "Checking $display_name (IPv6 address, IPv4 transport)"
      else
        log "$LOG_INFO" "Checking $display_name via IPv6"
      fi
      ipv6_result=$(run_lookup probe_service "$service" 6 "$EXTERNAL_IPV6")
    fi
  fi

  add_result "primary" "$display_name" "${ipv4_result#null}" "${ipv6_result#null}"
}

# Popular services (group "custom") and CDN checks: a handler per service
process_custom_service() {
  local group="$1"
  local service="$2"
  local ipv4_result ipv6_result display_name handler_func="${CUSTOM_SERVICES_HANDLERS[$service]}"

  case "$group" in
    cdn) display_name="${CDN_SERVICES[$service]:-$service}" ;;
    network) display_name="${NETWORK_SERVICES[$service]:-$service}" ;;
    *) display_name="${CUSTOM_SERVICES[$service]:-$service}" ;;
  esac

  set_spinner_text "$display_name"

  if [[ -z "$handler_func" ]]; then
    log "$LOG_WARN" "Unknown $group service: $service"
    return
  fi

  if [[ "$IPV6_ONLY" != true ]]; then
    log "$LOG_INFO" "Checking $display_name via IPv4"
    ipv4_result=$(run_lookup "$handler_func" 4)
  fi

  if ipv6_check_enabled; then
    log "$LOG_INFO" "Checking $display_name via IPv6"
    ipv6_result=$(run_lookup "$handler_func" 6)
  fi

  add_result "$group" "$display_name" "$ipv4_result" "$ipv6_result"
}

check_service() {
  local group="$1"
  local service="$2"

  if [[ "$group" == "primary" ]]; then
    process_service "$service"
  else
    process_custom_service "$group" "$service"
  fi
}

# Checks every service of the given groups, PARALLEL_JOBS at a time. In parallel mode
# each job writes its add_result line to its own file; the files are read back in the
# original order, so the table looks the same as with --parallel 1
run_service_groups() {
  local results_dir="$WORK_DIR/results"
  local tasks=() pids=()
  local group service task index running=0 ipv4 ipv6

  for group in "$@"; do
    for service in ${SERVICE_GROUPS[$group]}; do
      if printf "%s\n" "${EXCLUDED_SERVICES[@]}" | grep -Fxq "$service"; then
        log "$LOG_INFO" "Skipping service: $service"
        continue
      fi

      tasks+=("$group $service")
    done
  done

  log "$LOG_INFO" "Checking ${#tasks[@]} services, $PARALLEL_JOBS at a time"

  if ((PARALLEL_JOBS <= 1)); then
    for task in "${tasks[@]}"; do
      read -r group service <<<"$task"
      check_service "$group" "$service"
    done
    return
  fi

  mkdir -p "$results_dir"

  for index in "${!tasks[@]}"; do
    read -r group service <<<"${tasks[$index]}"
    (
      RESULT_OUT="$results_dir/$index"
      check_service "$group" "$service"
    ) &
    pids+=("$!")
    running=$((running + 1))

    # Only the check jobs are waited for: the spinner also runs in the background
    if ((running >= PARALLEL_JOBS)); then
      wait -n "${pids[@]}" 2>/dev/null
      running=$((running - 1))
    fi
  done

  wait "${pids[@]}"

  for index in "${!tasks[@]}"; do
    if [[ -f "$results_dir/$index" ]]; then
      IFS=$'\x1f' read -r group service ipv4 ipv6 <"$results_dir/$index"
      add_result "$group" "$service" "$ipv4" "$ipv6"
    fi
  done
}

finalize_json() {
  local t_primary t_custom t_cdn t_network
  local IFS=$'\n'

  if ((${#ARR_PRIMARY[@]} > 0)); then
    t_primary=$(printf '%s\n' "${ARR_PRIMARY[@]//|||/$'\t'}")
  fi

  if ((${#ARR_CUSTOM[@]} > 0)); then
    t_custom=$(printf '%s\n' "${ARR_CUSTOM[@]//|||/$'\t'}")
  fi

  if ((${#ARR_CDN[@]} > 0)); then
    t_cdn=$(printf '%s\n' "${ARR_CDN[@]//|||/$'\t'}")
  fi

  if ((${#ARR_NETWORK[@]} > 0)); then
    t_network=$(printf '%s\n' "${ARR_NETWORK[@]//|||/$'\t'}")
  fi

  RESULT_JSON=$(
    jq -n \
      --rawfile p <(printf "%s" "$t_primary") \
      --rawfile c <(printf "%s" "$t_custom") \
      --rawfile d <(printf "%s" "$t_cdn") \
      --rawfile n <(printf "%s" "$t_network") \
      --arg ipv4 "$EXTERNAL_IPV4" \
      --arg ipv6 "$EXTERNAL_IPV6" \
      --arg version "1" \
      --arg script_version "$SCRIPT_VERSION" \
      --arg latest_version "${LATEST_VERSION:-}" '
        def lines_to_array($raw):
          if ($raw | length) == 0 then [] else
          ($raw | split("\n"))
          | map(select(length > 0))
          | map(
              (split("\t")) as $f
              | {
                  service: $f[0],
                  ipv4: ( ($f[1] // "") | if length>0 then . else null end ),
                  ipv6: ( ($f[2] // "") | if length>0 then . else null end )
                }
            )
          end;

        {
          version: ($version|tonumber),
          script_version: $script_version,
          latest_version: ($latest_version | select(length > 0) // null),
          ipv4: ($ipv4 | select(length > 0) // null),
          ipv6: ($ipv6 | select(length > 0) // null),
          results: {
            primary: lines_to_array($p),
            custom:  lines_to_array($c),
            cdn:     lines_to_array($d),
            network: lines_to_array($n)
          }
        }
      '
  )
}

add_result() {
  local group="$1"
  local service="$2"
  local ipv4="$3"
  local ipv6="$4"

  ipv4=${ipv4//$'\n'/}
  ipv4=${ipv4//$'\t'/ }
  ipv6=${ipv6//$'\n'/}
  ipv6=${ipv6//$'\t'/ }

  # Parallel jobs hand their result to run_service_groups through a file
  if [[ -n "${RESULT_OUT:-}" ]]; then
    printf '%s\x1f%s\x1f%s\x1f%s\n' "$group" "$service" "$ipv4" "$ipv6" >"$RESULT_OUT"
    return
  fi

  case "$group" in
    primary) ARR_PRIMARY+=("$service|||$ipv4|||$ipv6") ;;
    custom) ARR_CUSTOM+=("$service|||$ipv4|||$ipv6") ;;
    cdn) ARR_CDN+=("$service|||$ipv4|||$ipv6") ;;
    network) ARR_NETWORK+=("$service|||$ipv4|||$ipv6") ;;
  esac
}

# Prints a table cell padded to a visible width; color codes in it take no space on screen
print_cell() {
  local text="$1"
  local width="$2"
  local plain="${text//$'\e'\[+([0-9;])m/}"
  local pad=$((width - ${#plain}))

  ((pad < 1)) && pad=1
  printf "%s%*s" "$text" "$pad" ""
}

declare -A GROUP_TITLES=(
  [primary]="GeoIP databases"
  [cdn]="CDN"
  [network]="IP reputation and DNS"
)

# Prints one group of the table. The first group gets the "Service IPv4 IPv6" header,
# the next ones start after an empty line. Each block has a title (popular services:
# one per CUSTOM_SECTIONS block) and its rows are indented. Fixed-width columns instead
# of tabs: values such as "Originals only" are longer than one tab stop
print_table_group() {
    local group="$1"
    local show_header="${2:-true}"
    local na="N/A"
    local show_ipv4=0
    local show_ipv6=0
    local name_width=26
    local value_width=16
    local section=""
    local row_section

    [[ "$IPV6_ONLY" != true && -n "$EXTERNAL_IPV4" ]] && show_ipv4=1
    [[ "$IPV4_ONLY" != true && -n "$EXTERNAL_IPV6" ]] && show_ipv6=1

    if [[ "$show_header" == true ]]; then
        print_cell "$(color TABLE_HEADER 'Service')" "$name_width"
        [[ $show_ipv4 -eq 1 ]] && print_cell "$(color TABLE_HEADER 'IPv4')" "$value_width"
        [[ $show_ipv6 -eq 1 ]] && print_cell "$(color TABLE_HEADER 'IPv6')" "$value_width"
    fi
    printf "\n"

    jq -r --arg group "$group" '
        (.results // {}) as $r
        | ($r[$group] // [])
        | .[]
        | [ .service, (.ipv4 // "N/A"), (.ipv6 // "N/A") ]
        | @tsv
    ' <<<"$RESULT_JSON" | while IFS=$'\t' read -r s v4 v6; do

        if [[ "$group" == "custom" ]]; then
            row_section="${CUSTOM_SECTION_OF[$s]:-Other}"
        else
            row_section="${GROUP_TITLES[$group]:-}"
        fi

        if [[ "$row_section" != "$section" ]]; then
            # An empty line between the blocks of the popular services
            [[ -n "$section" ]] && printf "\n"
            printf "%s\n" "$(color HEADER "$row_section")"
            section="$row_section"
        fi

        print_cell "  $(color SERVICE "$s")" "$name_width"

        if [[ $show_ipv4 -eq 1 ]]; then
            [[ "$v4" == "null" || -z "$v4" ]] && v4="$na"
            print_cell "$(format_value "$v4" "$na")" "$value_width"
        fi

        if [[ $show_ipv6 -eq 1 ]]; then
            [[ "$v6" == "null" || -z "$v6" ]] && v6="$na"
            print_cell "$(format_value "$v6" "$na")" "$value_width"
        fi

        printf "\n"
    done
}


print_header() {
  local ipv4 ipv6

  ipv4=$(process_json "$RESULT_JSON" ".ipv4")
  ipv6=$(process_json "$RESULT_JSON" ".ipv6")

  printf "%s\n\n" "$(color URL "ipregion-lucx $LUCX_VERSION (на базе ipregion-fixed $SCRIPT_VERSION, Davoyan/ipregion)")"
  [[ -n "$TARGET_IP" ]] && printf "%s\n\n" "$(color WARN "Режим проверки чужого IP: только GeoIP и флаги VPN/хостинг")"

  if [[ -n "$EXTERNAL_IPV4" ]]; then
    printf "%s: %s\n" "$(color HEADER 'IPv4')" "$(bold "$([[ "$MASK_IP" == true ]] && mask_ipv4 "$ipv4" || echo "$ipv4")")"
  fi

  if [[ -n "$EXTERNAL_IPV6" ]]; then
    printf "%s: %s\n" "$(color HEADER 'IPv6')" "$(bold "$([[ "$MASK_IP" == true ]] && mask_ipv6 "$ipv6" || echo "$ipv6")")"
  fi

  printf "%s: %s\n\n" "$(color HEADER 'ASN')" "$(bold "AS$asn $asn_name")"
}

print_legend() {
  local separator="|||"
  echo
  printf "%s\n\n" "$(color HEADER 'Legend')"

  local stats
  stats=$(jq -r '
    def clean:
      tostring
      | gsub("\u001b\\[[0-9;]*m"; "")
      | select(test("^[A-Z]{2}$")); # only country codes: not Yes/No/Blocked/Timeout/N/A

    def counts(stream):
      [stream | select(. != null) | clean] as $arr
      | reduce ($arr[]) as $c ({}; .[$c] += 1)
      | {total: ($arr | length), counts: .};

    {
      ipv4: counts(
        (.results.primary[].ipv4?, .results.custom[].ipv4?)
      ),
      ipv6: counts(
        (.results.primary[].ipv6?, .results.custom[].ipv6?)
      )
    }
  ' <<<"$RESULT_JSON")

  local codes
  codes=$(jq -r '
    [
      (.ipv4.counts | keys[]?),
      (.ipv6.counts | keys[]?)
    ] | unique[]
  ' <<<"$stats")

  local show_ipv4=true show_ipv6=true
  if [[ "${IPV4_ONLY,,}" == "true" && "${IPV6_ONLY,,}" != "true" ]]; then
    show_ipv6=false
  fi
  if [[ "${IPV6_ONLY,,}" == "true" && "${IPV4_ONLY,,}" != "true" ]]; then
    show_ipv4=false
  fi
  
  if [[ -n "$EXTERNAL_IPV6" ]]; then
    show_ipv6=true
  else
    show_ipv6=false
  fi

  {
    local header_parts=()
    header_parts+=("$(color TABLE_HEADER 'Code')")
    header_parts+=("$(color TABLE_HEADER 'Country')")
    $show_ipv4 && header_parts+=("$(color TABLE_HEADER '% IPv4')")
    $show_ipv6 && header_parts+=("$(color TABLE_HEADER '% IPv6')")

    local header="${header_parts[0]}"
    for ((i=1; i<${#header_parts[@]}; i++)); do
      header+="$separator${header_parts[i]}"
    done
    echo "$header"

    while read -r code; do
      [[ -z "$code" ]] && continue
      local country ipv4_num ipv6_num ipv4_str ipv6_str
      country="${COUNTRY_NAMES[$code]:-Unknown}"

      ipv4_num=$(jq -r --arg c "$code" '
        if (.ipv4.total == 0) then 0
        else ((.ipv4.counts[$c] // 0) / .ipv4.total * 100 | round)
        end
      ' <<<"$stats")

      ipv6_num=$(jq -r --arg c "$code" '
        if (.ipv6.total == 0) then 0
        else ((.ipv6.counts[$c] // 0) / .ipv6.total * 100 | round)
        end
      ' <<<"$stats")

      ipv4_str=""
      ipv6_str=""
      [[ "$ipv4_num" -ne 0 ]] && ipv4_str="${ipv4_num}%"
      [[ "$ipv6_num" -ne 0 ]] && ipv6_str="${ipv6_num}%"

      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$ipv4_num" "$ipv6_num" "$(color SERVICE "$code")" "$(format_value "$country" "$country")" "$ipv4_str" "$ipv6_str"
    done <<< "$codes" \
      | sort -t$'\t' -k1,1nr -k2,2nr \
      | awk -F $'\t' -v OFS="$separator" \
        "$(
          if $show_ipv4 && $show_ipv6; then
            echo '{print $3,$4,$5,$6}'
          elif $show_ipv4; then
            echo '{print $3,$4,$5}'
          elif $show_ipv6; then
            echo '{print $3,$4,$6}'
          else
            echo '{print $3,$4,$5,$6}'
          fi
        )"

  } | column -t -s "$separator"
}

# Runs in the background while the services are checked: reads SCRIPT_VERSION from the
# first 2 KB of the script on GitHub. Failures are silent, the result goes to a file
start_update_check() {
  if [[ "$UPDATE_CHECK" != true ]]; then
    return
  fi

  (
    make_request GET "$UPDATE_CHECK_URL" --header "Range: bytes=0-2047" \
      | grep -m 1 -oP '^SCRIPT_VERSION="\K[0-9.]+(?=")' >"$WORK_DIR/latest_version"
  ) &
  UPDATE_CHECK_PID=$!
}

# Prints the version found by start_update_check, or nothing
get_latest_version() {
  local latest

  if [[ -z "$UPDATE_CHECK_PID" ]]; then
    return
  fi

  wait "$UPDATE_CHECK_PID" 2>/dev/null
  latest=$(cat "$WORK_DIR/latest_version" 2>/dev/null)

  if [[ "$latest" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "$latest"
  fi
}

# True when version $1 is newer than version $2 (numeric, dot by dot: 2026.10.23.10 > 2026.10.23.9)
version_newer() {
  local a b i
  IFS=. read -ra a <<<"$1"
  IFS=. read -ra b <<<"$2"

  for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
    if ((10#${a[i]:-0} > 10#${b[i]:-0})); then
      return 0
    fi
    if ((10#${a[i]:-0} < 10#${b[i]:-0})); then
      return 1
    fi
  done

  return 1
}

print_update_notice() {
  local latest="$1"

  if [[ -z "$latest" ]] || ! version_newer "$latest" "$SCRIPT_VERSION"; then
    return
  fi

  printf "\n%s\n" "$(color WARN "A newer version is available: $latest (this one is $SCRIPT_VERSION). Run the latest:")"
  printf "%s\n" "$(color URL "bash <(curl -fsSL $UPDATE_CHECK_URL)")"
}

print_results() {
  LATEST_VERSION=$(get_latest_version)
  finalize_json

  if [[ "$JSON_OUTPUT" == true ]]; then
    echo "$RESULT_JSON" | jq
    return
  fi

  print_header

  case "$GROUPS_TO_SHOW" in
    primary | custom | cdn | network)
      print_table_group "$GROUPS_TO_SHOW"
      ;;
    target)
      print_table_group "primary"
      print_table_group "network" false
      print_legend
      print_summary
      ;;
    *)
      print_table_group "custom"
      print_table_group "primary" false
      # CDN and network rows are not countries of the IP: not in the legend
      print_table_group "cdn" false
      print_table_group "network" false
      print_legend
      print_summary
      ;;
  esac

  print_update_notice "$LATEST_VERSION"
}

# Turns the availability rows of the popular services and the network flags into lines
# "kind<TAB>list": works, blocked, unknown, flags
SUMMARY_FILTER='
  def plain: tostring | gsub("\u001b\\[[0-9;]*m"; "");
  def names: {
    "Google Search Captcha": "Google Search", "YouTube Premium": "YouTube Premium",
    "YouTube Music": "YouTube Music", "ChatGPT Access": "ChatGPT", "Claude Access": "Claude",
    "Gemini Access": "Gemini", "Copilot Access": "Copilot", "Grok Access": "Grok", "Netflix Catalog": "Netflix",
    "Disney+": "Disney+", "Spotify Signup": "Spotify", "Reddit": "Reddit", "Amazon Prime": "Prime Video"
  };
  def kind:
    if .service == "Google Search Captcha" then
      (if .value == "No" then "works" elif .value == "Yes" then "blocked" else "unknown" end)
    elif .value == "Yes" or .value == "Full" or (.value | test("^[A-Z]{2}$")) then "works"
    elif .value == "No" or .value == "Blocked" or .value == "Originals only" then "blocked"
    else "unknown" end;
  def row_label:
    if .service == "Netflix Catalog" and .value == "Originals only" then "Netflix (Originals only)"
    elif .service == "Google Search Captcha" and .value == "Yes" then "Google Search (captcha)"
    else names[.service] end;

  ([ (.results.custom // [])[] | select(names[.service]) | {service, value: ((.[$v] // "") | plain)} ]
    | map({kind: kind, label: row_label})) as $rows
  | ([ (.results.network // [])[] | select(.service != "DNS resolver")
       | {service, value: ((.[$v] // "") | plain)}
       | select(.value | IN("", "N/A", "null", "Timeout", "RateLimited") | not)
       | (.service | capture("\\((?<s>[^)]*)\\)").s // "") as $source
       | (if .value == "Yes" then [.service | sub(" \\(.*"; "")] else (.value | split(", ")) end)
       | map(select(IN("No", "ISP", "Business", "Education") | not))
       | select(length > 0)
       | join(", ") + " (" + $source + ")" ]) as $flags
  | ($rows | map(select(.kind == "works") | .label) | "works\t" + join(", ")),
    ($rows | map(select(.kind == "blocked") | .label) | "blocked\t" + join(", ")),
    ($rows | map(select(.kind == "unknown") | .label) | "unknown\t" + join(", ")),
    ("flags\t" + ($flags | join(", ")))
'

# Short verdict after the table: what works from this IP and what does not, per IP version
print_summary() {
  local version label kind list title color_name

  for version in ipv4 ipv6; do
    if [[ "$version" == ipv4 ]]; then
      [[ "$IPV6_ONLY" != true && -n "$EXTERNAL_IPV4" ]] || continue
      label="IPv4"
    else
      [[ "$IPV4_ONLY" != true && -n "$EXTERNAL_IPV6" ]] || continue
      label="IPv6"
    fi

    printf "\n%s\n" "$(color HEADER "Summary ($label)")"

    while IFS=$'\t' read -r kind list; do
      case "$kind" in
        works) title="Works"; color_name="SERVICE" ;;
        blocked) title="Not available"; color_name="HEART" ;;
        unknown) title="Not checked"; color_name="NULL" ;;
        flags) title="IP flagged as"; color_name="WARN"; list="${list:-nothing}" ;;
      esac

      [[ -z "$list" ]] && continue
      print_cell "$(color TABLE_HEADER "$title")" 16
      printf "%s\n" "$(color "$color_name" "$list")"
    done < <(jq -r --arg v "$version" "$SUMMARY_FILTER" <<<"$RESULT_JSON")
  done
}

# Итог по GeoIP-группе: самая частая страна и сверка с --expect. Код выхода 3 при расхождении
compute_verdict() {
  local v=ipv4
  [[ "$IPV6_ONLY" == true ]] && v=ipv6

  jq -r --arg v "$v" '
    def plain: tostring | gsub("\u001b\\[[0-9;]*m"; "");
    [ (.results.primary // [])[] | ((.[$v] // "") | plain) | select(test("^[A-Z]{2}$")) ] as $c
    | if ($c | length) == 0 then "" else
        ($c | group_by(.) | map({cc: .[0], n: length}) | sort_by(-.n)) as $g
        | "\($g[0].cc)\t\($g[0].n)\t\($c | length)\t" + ($g | map("\(.cc)=\(.n)") | join(" "))
      end' <<<"$RESULT_JSON"
}

print_verdict() {
  local line top top_n total dist expect_n pct

  line=$(compute_verdict)

  if [[ -z "$line" ]]; then
    if [[ -n "$EXPECT_CC" ]]; then
      [[ "$JSON_OUTPUT" == true ]] || printf "\n%s\n" "$(color HEART "Итог: GeoIP-сервисы не ответили, страну проверить не удалось")"
      VERDICT_EXIT=4
    fi
    return
  fi

  IFS=$'\t' read -r top top_n total dist <<<"$line"

  if [[ -n "$EXPECT_CC" ]]; then
    expect_n=$(grep -o "\b${EXPECT_CC}=[0-9]*" <<<"$dist" | cut -d= -f2)
    expect_n=${expect_n:-0}
    pct=$((expect_n * 100 / total))
    if ((pct >= 75)); then
      VERDICT_MSG="$(color SERVICE "Итог: ОК — ожидали $EXPECT_CC, так отвечают $expect_n из $total сервисов")"
    else
      VERDICT_MSG="$(color HEART "Итог: НЕ СОВПАДАЕТ — ожидали $EXPECT_CC (отвечают $expect_n из $total), большинство говорит $top ($top_n). Все ответы: $dist")"
      VERDICT_EXIT=3
    fi
  else
    VERDICT_MSG="$(bold "Итог: страна по GeoIP — $top ($top_n из $total сервисов).") $(color NULL "Все ответы: $dist")"
  fi

  [[ "$JSON_OUTPUT" == true ]] || printf "\n%s\n" "$VERDICT_MSG"
}

lookup_cloudflare() {
  local ip_version="$1"
  local response

  response=$(make_request GET "https://www.cloudflare.com/cdn-cgi/trace" --ip-version "$ip_version")
  while IFS='=' read -r key value; do
    if [[ "$key" == "loc" ]]; then
      echo "$value"
      break
    fi
  done <<<"$response"
}

lookup_iplocation_com() {
  local ip_version="$1"
  local response ip

  if [[ -n "$EXTERNAL_IPV4" ]]; then
    ip="$EXTERNAL_IPV4"
  else
    ip="$EXTERNAL_IPV6"
  fi

  response=$(make_request POST "https://iplocation.com" --ip-version "$ip_version" --user-agent "$USER_AGENT" --data "ip=$ip")
  process_json "$response" ".country_code"
}

lookup_2ip() {
  local ip_version="$1"
  local response

  # api.2ip.io describes the caller's own address, so the transport picks IPv4 or IPv6
  response=$(make_request GET "https://api.2ip.io" --ip-version "$ip_version")
  process_json "$response" ".code"
}

get_country_code() {
    local country="$1"
    local json

    json=$(make_request GET "https://restcountries.com/v3.1/all?fields=name,cca2")
    if [[ -z "$json" ]] || ! grep -q '"name"' <<<"$json"; then
        echo ""
        return
    fi

    jq -r --arg COUNTRY "$country" '
        .[]
        | select(.name.common | ascii_downcase == ($COUNTRY | ascii_downcase))
        | .cca2
    ' <<<"$json"
}

lookup_google() {
  local ip_version="$1"
  local sed_filter='s/.*"[a-z]\{2\}_\([A-Z]\{2\}\)".*/\1/p'
  local sed_fallback_filter='s/.*"[a-z]\{2\}-\([A-Z]\{2\}\)".*/\1/p'
  local response result

  response=$(make_request GET "https://www.google.com" \
    --user-agent "$USER_AGENT" \
    --ip-version "$ip_version")

  result=$(sed -n "$sed_filter" <<<"$response")

  if [[ -z "$result" ]]; then
    result=$(sed -n "$sed_fallback_filter" <<<"$response" | tail -n 1)
  fi
  
  if [[ -z "$result" ]]; then
    local country

    country=$(make_request GET 'https://play.google.com/' --follow --ip-version "$ip_version" \
      --user-agent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36' \
      --header 'accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7' \
      --header 'accept-language: en-US;q=0.9' \
      --header 'priority: u=0, i' \
      --header 'sec-ch-ua: "Chromium";v="131", "Not_A Brand";v="24", "Google Chrome";v="131"' \
      --header 'sec-ch-ua-mobile: ?0' \
      --header 'sec-ch-ua-platform: "Windows"' \
      --header 'sec-fetch-dest: document' \
      --header 'sec-fetch-mode: navigate' \
      --header 'sec-fetch-site: none' \
      --header 'sec-fetch-user: ?1' \
      --header 'upgrade-insecure-requests: 1' \
      | grep -oP '<div class="yVZQTb">\K[^<(]+')

	country=$(echo "$country" | xargs)  # убираем пробелы
	if [[ -n "$country" ]]; then
		result=$(get_country_code "$country")
	fi  
  fi

  echo "$result"
}

lookup_twitch() {
  local ip_version="$1"
  local response

  response=$(make_request POST "https://gql.twitch.tv/gql" \
    --header 'Client-Id: kimne78kx3ncx6brgo4mv6wki5h1ko' \
    --json '[{"operationName":"VerifyEmail_CurrentUser","variables":{},"extensions":{"persistedQuery":{"version":1,"sha256Hash":"f9e7dcdf7e99c314c82d8f7f725fab5f99d1df3d7359b53c9ae122deec590198"}}}]' \
    --ip-version "$ip_version")
  process_json "$response" ".[0].data.requestInfo.countryCode"
}

lookup_chatgpt() {
  local ip_version="$1"
  local response

  response=$(make_request POST "https://ab.chatgpt.com/v1/initialize" --ip-version "$ip_version" \
    --header "Statsig-Api-Key: client-zUdXdSTygXJdzoE0sWTkP8GKTVsUMF2IRM7ShVO2JAG")
  process_json "$response" ".derived_fields.country"
}

lookup_netflix() {
  local ip_version="$1"
  local response

  response=$(make_request GET "https://api.fast.com/netflix/speedtest/v2?https=true&token=YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm&urlCount=1" --ip-version "$ip_version")

  if is_valid_json "$response"; then
    process_json "$response" ".client.location.country"
  else
    echo ""
  fi
}

# api.openai.com answers 403 "unsupported_country_region_territory" where ChatGPT is not offered
lookup_chatgpt_access() {
  local ip_version="$1"
  local response http_code

  response=$(make_request GET "https://api.openai.com/compliance/cookie_requirements" \
    --ip-version "$ip_version" \
    --header "Authorization: Bearer null" \
    --with-status)
  http_code=$(tail -n1 <<<"$response")

  if grep -q "unsupported_country" <<<"$response"; then
    print_value_or_colored "No" "HEART"
  elif [[ "$http_code" == "200" ]]; then
    print_value_or_colored "Yes" "SERVICE"
  fi
}

# Without a key the Anthropic API answers 401 in supported regions and 403 "Request not allowed" elsewhere
lookup_claude_access() {
  local ip_version="$1"
  local response http_code

  response=$(make_request POST "https://api.anthropic.com/v1/messages" \
    --ip-version "$ip_version" \
    --header "anthropic-version: 2023-06-01" \
    --json '{}' \
    --with-status)
  http_code=$(tail -n1 <<<"$response")

  if [[ "$http_code" == "401" ]]; then
    print_value_or_colored "Yes" "SERVICE"
  elif [[ "$http_code" == "403" ]] && grep -q "Request not allowed" <<<"$response"; then
    print_value_or_colored "No" "HEART"
  fi
}

# Netflix shows only its own titles to some regions and to IPs it takes for proxies.
# 81280792 and 70143836 are licensed titles available in most regions; 80018499 opened
# everywhere in our tests and is the control that the title pages work at all
lookup_netflix_catalog() {
  local ip_version="$1"
  local title response checked=0 available=0

  for title in 81280792 70143836; do
    response=$(make_request GET "https://www.netflix.com/title/$title" --follow \
      --ip-version "$ip_version" --user-agent "$USER_AGENT")

    if [[ -z "$response" ]]; then
      continue
    fi

    checked=$((checked + 1))
    if ! grep -q "Oh no!" <<<"$response"; then
      available=$((available + 1))
    fi
  done

  if ((checked == 0)); then
    return
  fi

  if ((available > 0)); then
    print_value_or_colored "Full" "SERVICE"
    return
  fi

  response=$(make_request GET "https://www.netflix.com/title/80018499" --follow \
    --ip-version "$ip_version" --user-agent "$USER_AGENT")

  if [[ -n "$response" ]] && ! grep -q "Oh no!" <<<"$response"; then
    print_value_or_colored "Originals only" "HEART"
  fi
}

# Disney+ device registration (same request as in vernette/ipregion): the session says
# whether the service works here and which country it sees
lookup_disney_plus() {
  local ip_version="$1"
  local response

  response=$(make_request POST "https://disney.api.edge.bamgrid.com/graph/v1/device/graphql" \
    --ip-version "$ip_version" \
    --header "Authorization: Bearer $DISNEY_PLUS_API_KEY" \
    --json "$DISNEY_PLUS_JSON_BODY")

  if ! is_valid_json "$response"; then
    return
  fi

  # Some hosting IPs get an error instead of a session: "... description 'Forbidden location'"
  if grep -q "Forbidden location" <<<"$response"; then
    print_value_or_colored "No" "HEART"
    return
  fi

  case "$(process_json "$response" ".extensions.sdk.session.inSupportedLocation")" in
    true)
      process_json "$response" ".extensions.sdk.session.location.countryCode"
      ;;
    false)
      print_value_or_colored "No" "HEART"
      ;;
  esac
}

lookup_spotify() {
  local ip_version="$1"
  local response

  response=$(make_request GET "https://accounts.spotify.com/status" --ip-version "$ip_version")

  sed -n 's/.*"geoLocationCountryCode":"\([^"]*\)".*/\1/p' <<<"$response"
}

lookup_deezer() {
  local ip_version="$1"
  local response

  response=$(make_request GET "https://www.deezer.com/en/offers" --ip-version "$ip_version")

  echo "$response" | sed -n "s/.*'country': '\(.*\)'.*/\1/p"
}


lookup_reddit() {
  local ip_version="$1"
  local basic_access_token="Basic b2hYcG9xclpZdWIxa2c6"
  local user_agent="Reddit/Version 2025.29.0/Build 2529021/Android 13"
  local response access_token

  response=$(make_request POST "https://www.reddit.com/auth/v2/oauth/access-token/loid" \
    --ip-version "$ip_version" \
    --user-agent "$user_agent" \
    --header "Authorization: $basic_access_token" \
    --json '{"scopes":["email"]}' \
    --with-status)

  if is_reddit_block_page "$response"; then
    print_value_or_colored "Blocked" "HEART"
    return
  fi

  access_token=$(process_json "$(sed '$d' <<<"$response")" ".access_token")

  response=$(make_request POST "https://gql-fed.reddit.com" \
    --ip-version "$ip_version" \
    --user-agent "$user_agent" \
    --header "Authorization: Bearer $access_token" \
    --json '{"operationName":"UserLocation","variables":{},"extensions":{"persistedQuery":{"version":1,"sha256Hash":"f07de258c54537e24d7856080f662c1b1268210251e5789c8c08f20d76cc8ab2"}}}' \
    --with-status)

  if is_reddit_block_page "$response"; then
    print_value_or_colored "Blocked" "HEART"
    return
  fi

  process_json "$(sed '$d' <<<"$response")" ".data.userLocation.countryCode"
}

# Reddit answers datacenter IPs with HTTP 403 and an HTML page "blocked by network security".
# Takes make_request --with-status output (HTTP code on the last line)
is_reddit_block_page() {
  local response="$1"

  [[ "$(tail -n1 <<<"$response")" == "403" ]] && grep -qi "blocked by network security" <<<"$response"
}

lookup_reddit_guest_access() {
  local ip_version="$1"
  local response is_available color_name

  response=$(make_request GET "https://www.reddit.com" --ip-version "$ip_version" --user-agent "$USER_AGENT")

  if [[ -n "$response" ]]; then
    is_available="Yes"
    color_name="SERVICE"
  else
    is_available="No"
    color_name="HEART"
  fi

  print_value_or_colored "$is_available" "$color_name"
}

lookup_youtube() {
  local ip_version="$1"
  local result

  result=$(make_request GET "https://www.youtube.com" --ip-version "$ip_version" --user-agent "$USER_AGENT" \
    | grep -oP '"countryCode":"\K\w+' | head -n 1)

  # YouTube and Google share the region; ask Google when the page has no country
  if [[ ! "$result" =~ ^[A-Z]{2}$ ]]; then
    result=$(lookup_google "$ip_version")
  fi

  echo "$result"
}


lookup_youtube_premium() {
  local ip_version="$1"
  local response is_available

  response=$(make_request GET "https://www.youtube.com/premium" \
    --ip-version "$ip_version" \
    --user-agent "$USER_AGENT" \
    --header "Cookie: SOCS=CAISNQgDEitib3FfaWRlbnRpdHlmcm9udGVuZHVpc2VydmVyXzIwMjUwNzMwLjA1X3AwGgJlbiACGgYIgPC_xAY" \
    --header "Accept-Language: en-US,en;q=0.9")

  if [[ -z "$response" ]]; then
    echo ""
    return
  fi

  is_available=$(grep -io "youtube premium is not available in your country" <<<"$response")

  if [[ -z "$is_available" ]]; then
    is_available="Yes"
    color_name="SERVICE"
  else
    is_available="No"
    color_name="HEART"
  fi

  print_value_or_colored "$is_available" "$color_name"
}

lookup_youtube_music() {
  local ip_version="$1"
  local response is_available

  response=$(make_request GET "https://music.youtube.com/" \
    --ip-version "$ip_version" \
    --user-agent "$USER_AGENT" \
    --header "Cookie: SOCS=CAISNQgDEitib3FfaWRlbnRpdHlmcm9udGVuZHVpc2VydmVyXzIwMjUwNzMwLjA1X3AwGgJlbiACGgYIgPC_xAY" \
    --header "Accept-Language: en-US,en;q=0.9")

  if [[ -z "$response" ]]; then
    echo ""
    return
  fi

  is_available=$(grep -io "YouTube Music is not available in your area" <<<"$response")

  if [[ -z "$is_available" ]]; then
    is_available="Yes"
    color_name="SERVICE"
  else
    is_available="No"
    color_name="HEART"
  fi

  print_value_or_colored "$is_available" "$color_name"
}

lookup_google_search_captcha() {
  local ip_version="$1"
  local response is_captcha color_name

  response=$(make_request GET "https://www.google.com/search?q=cats" --ip-version "$ip_version" \
    --user-agent "$USER_AGENT" \
    --header "Accept-Language: en-US,en;q=0.9")

  if [[ -z "$response" ]]; then
    echo ""
    return
  fi

  is_captcha=$(grep -iE "unusual traffic from|is blocked|unaddressed abuse" <<<"$response")

  if [[ -z "$is_captcha" ]]; then
    is_captcha="No"
    color_name="SERVICE"
  else
    is_captcha="Yes"
    color_name="HEART"
  fi

  print_value_or_colored "$is_captcha" "$color_name"
}

lookup_bing() {
  local ip_version="$1"
  local response region

  response=$(make_request GET "https://www.bing.com/search?q=cats" --follow --ip-version "$ip_version" --user-agent "$USER_AGENT")
  region=$(grep -woP 'Region\s{0,}:\s{0,}"\K[^"]+' <<<"$response" | head -n 1)

  if grep -q 'cn.bing.com' <<<"$response"; then
    region='CN'
  fi

  region="${region:0:2}"

  # WW (worldwide), XL (Latin America) and other market codes are not countries
  if [[ -z "$region" || "$region" == "WW" || "$region" == "EU" || -z "${COUNTRY_NAMES[$region]+x}" ]]; then
    response=$(make_request GET "https://login.live.com" --ip-version "$ip_version" --user-agent "$USER_AGENT")
    region=$(grep -oP '"sRequestCountry":"\K[^"]*' <<<"$response" | head -n 1)
  fi

  echo "$region"
}

lookup_spotify_signup() {

  local ip_version="$1"
  local response status is_country_launched available color_name

  response=$(make_request GET "https://spclient.wg.spotify.com/signup/public/v1/account/?validate=1&key=$SPOTIFY_API_KEY" \
    --ip-version "$ip_version" \
    --header "X-Client-Id: $SPOTIFY_CLIENT_ID" \
    --user-agent "$USER_AGENT")

  status=$(process_json "$response" ".status")
  is_country_launched=$(process_json "$response" ".is_country_launched")

  if [[ "$status" == "120" || "$status" == "320" || "$is_country_launched" == "false" ]]; then
    available="No"
    color_name="HEART"
  else
    available="Yes"
    color_name="SERVICE"
  fi

  print_value_or_colored "$available" "$color_name"
}

lookup_amazon_prime() {
  local ip_version="$1"
  local response region

  response=$(make_request GET "https://www.primevideo.com" --follow --ip-version "$ip_version" --user-agent "$USER_AGENT")
  region=$(grep -woP '"currentTerritory":"\K[^"]+' <<<"$response" | head -n 1)

  if grep -qi 'isServiceRestricted' <<<"$response"; then
    print_value_or_colored "No" "HEART"
  else
    echo "${region:0:2}"
  fi
}

# Gemini: the country Google sees, looked up in Google's list of regions where the Gemini API
# is available (the approach of vernette/ipregion). Names are compared word by word
lookup_gemini_access() {
  local ip_version="$1"
  local country name regions

  country=$(lookup_google "$ip_version")
  if [[ ! "$country" =~ ^[A-Z]{2}$ ]]; then
    return
  fi

  name="${GEMINI_REGION_NAMES[$country]:-${COUNTRY_NAMES[$country]}}"
  regions=$(make_request GET "$GEMINI_REGIONS_URL" --ip-version "$ip_version")

  if [[ -z "$name" ]] || ! grep -q '^- ' <<<"$regions"; then
    return
  fi

  if jq -en --arg md "$regions" --arg name "$name" "$GEMINI_MATCH_FILTER" >/dev/null; then
    print_value_or_colored "Yes" "SERVICE"
  else
    print_value_or_colored "No" "HEART"
  fi
}

# copilot.microsoft.com sits behind Cloudflare, which answers "error code: 1009"
# (access from this country is banned) where Copilot is not offered
lookup_copilot_access() {
  local ip_version="$1"
  local response http_code

  response=$(make_request GET "https://copilot.microsoft.com/" \
    --ip-version "$ip_version" --user-agent "$USER_AGENT" --with-status)
  http_code=$(tail -n1 <<<"$response")

  if grep -q "error code: 1009" <<<"$response"; then
    print_value_or_colored "No" "HEART"
  elif [[ "$http_code" == "200" ]]; then
    print_value_or_colored "Yes" "SERVICE"
  fi
}

# Without a key the xAI API answers 401 where Grok works, and 403 with a page
# "This service is not available in your region." elsewhere (grok.com answers the same way)
lookup_grok_access() {
  local ip_version="$1"
  local response http_code

  response=$(make_request GET "https://api.x.ai/v1/models" --ip-version "$ip_version" --with-status)
  http_code=$(tail -n1 <<<"$response")

  if [[ "$http_code" == "401" ]]; then
    print_value_or_colored "Yes" "SERVICE"
  elif [[ "$http_code" == "403" ]] && grep -q "not available in your region" <<<"$response"; then
    print_value_or_colored "No" "HEART"
  fi
}

# Address checked in the "network" rows and the transport for the request: these services
# take the address in the URL, so IPv4 transport works for an IPv6 address too
external_ip_for() {
  if [[ "$1" == "6" ]]; then
    echo "$EXTERNAL_IPV6"
  else
    echo "$EXTERNAL_IPV4"
  fi
}

network_transport() {
  if [[ -n "$EXTERNAL_IPV4" && "$IPV6_ONLY" != true ]]; then
    echo 4
  else
    echo 6
  fi
}

# The ipinfo.io widget answer for the IPv4 ($1 = 4) or IPv6 address, fetched once per run: the
# ipinfo.io row and the "Network (ipinfo)" row run in parallel, the first one takes a lock and
# fetches, the other waits for the file. Its HTTP statuses are replayed into the caller's
# STATUS_LOG, so a 429 still shows as RateLimited in both rows.
# ipinfo answers freely only about the address the request comes from; lookups of other addresses
# have a small daily quota. So each address is asked over its own IP version: ipinfo.io has no
# IPv6, its IPv6 host is v6.ipinfo.io
ipinfo_widget() {
  local cache="$WORK_DIR/ipinfo_$1"
  local host="ipinfo.io"
  local i

  if [[ "$1" == "6" ]]; then
    host="v6.ipinfo.io"
  fi

  if mkdir "$cache.lock" 2>/dev/null; then
    STATUS_LOG="$cache.status" make_request GET "https://$host/widget/demo/$(external_ip_for "$1")" \
      --ip-version "$1" >"$cache.tmp"
    mv "$cache.tmp" "$cache"
  else
    for ((i = 0; i < (CURL_TIMEOUT + 2) * 10; i++)); do
      [[ -f "$cache" ]] && break
      sleep 0.1
    done
  fi

  if [[ -n "${STATUS_LOG:-}" && -f "$cache.status" ]]; then
    cat "$cache.status" >>"$STATUS_LOG"
  fi

  cat "$cache" 2>/dev/null
}

# ipinfo.io in one request (it rate-limits repeated ones): the network type (Hosting, ISP,
# Business, Education) followed by the VPN, Proxy, Tor and Relay flags, e.g. "Hosting, VPN"
lookup_ipinfo_network() {
  local response network

  response=$(ipinfo_widget "$1")
  is_valid_json "$response" || return
  network=$(process_json "$response" '
    .data as $d
    | ($d.asn.type // $d.company.type // "") as $type
    | [ (if $type == "isp" then "ISP" elif $type != "" then ($type[:1] | ascii_upcase) + $type[1:] else empty end),
        ($d.privacy // {} | (select(.vpn) | "VPN"), (select(.proxy) | "Proxy"), (select(.tor) | "Tor"), (select(.relay) | "Relay")) ]
    | join(", ")')

  case "$network" in
    "") ;;
    ISP | Business | Education) print_value_or_colored "$network" "SERVICE" ;;
    *) print_value_or_colored "$network" "HEART" ;;
  esac
}

# Hosting flag by ip-api.com (the same demo endpoint as the ip-api.com row)
lookup_ipapi_hosting() {
  local response

  response=$(make_request GET "https://demo.ip-api.com/json/$(external_ip_for "$1")?fields=status,hosting" \
    --ip-version "$(network_transport)" --header "Origin: https://ip-api.com")
  is_valid_json "$response" || return

  case "$(process_json "$response" '.hosting')" in
    true) print_value_or_colored "Yes" "HEART" ;;
    false) print_value_or_colored "No" "SERVICE" ;;
  esac
}

# proxycheck.io: "VPN", "Proxy" and the like, or No. Free without a key: 100 queries a day per IP
lookup_proxycheck() {
  local ip response

  ip=$(external_ip_for "$1")
  response=$(make_request GET "https://proxycheck.io/v2/$ip?vpn=1&asn=1" --ip-version "$(network_transport)")
  is_valid_json "$response" || return

  if [[ "$(process_json "$response" '.status')" == "denied" ]]; then
    print_value_or_colored "RateLimited" "NULL"
    return
  fi

  case "$(jq -r --arg ip "$ip" '.[$ip].proxy // empty' <<<"$response")" in
    yes) print_value_or_colored "$(jq -r --arg ip "$ip" '.[$ip].type // "Proxy"' <<<"$response")" "HEART" ;;
    no) print_value_or_colored "No" "SERVICE" ;;
  esac
}

# The resolver that looks up names for this host (or for the proxy, with -p): edns.ip-api.com
# redirects to a random subdomain and reports which resolver asked for it. DoH is bypassed here
lookup_dns_resolver() {
  local response geo country org code

  # One resolver serves both IP versions, and edns.ip-api.com has no IPv6: check it once
  if [[ "$1" == "6" && -n "$EXTERNAL_IPV4" && "$IPV6_ONLY" != true ]]; then
    print_value_or_colored "same as IPv4" "NULL"
    return
  fi

  response=$(make_request GET "https://edns.ip-api.com/json" --follow --system-dns --ip-version "$1")
  is_valid_json "$response" || return

  geo=$(process_json "$response" '.dns.geo // empty')
  country="${geo%% - *}"
  org="${geo#* - }"
  org="${org%%[ ,.]*}"
  code=$(country_code_by_name "$country")

  if [[ -n "$code" ]]; then
    echo "$code $org"
  elif [[ -n "$geo" ]]; then
    echo "${org:-$country}"
  fi
}

lookup_apple() {
  local ip_version="$1"
  make_request GET "https://gspe1-ssl.ls.apple.com/pep/gcc" --ip-version "$ip_version"
}

lookup_steam() {
  local ip_version="$1"
  local tmpresult

  tmpresult=$(make_request HEAD "https://store.steampowered.com" --ip-version "$ip_version" --user-agent "$USER_AGENT")

  echo "$tmpresult" | grep -oP 'steamCountry=\K[^%;]*'
}


lookup_tiktok() {
  local ip_version="$1"
  local response

  response=$(make_request GET "https://www.tiktok.com/api/v1/web-cookie-privacy/config?appId=1988" --ip-version "$ip_version")
  process_json "$response" ".body.appProps.region"
}

lookup_youtube_cdn() {
  local ip_version="$1"
  local response iata location

  local name

  response=$(make_request GET "https://redirector.googlevideo.com/report_mapping?di=no" --ip-version "$ip_version")
  name=$(awk 'NR == 1 {print $3}' <<<"$response")

  # Mapping names seen: "fra16s69", "waw40s03" (IATA + digits) and "tzfraa-cd" (tz + IATA + letter)
  if [[ "$name" =~ (^|-)([a-z]{3})[0-9] ]]; then
    iata="${BASH_REMATCH[2]}"
  elif [[ "$name" =~ ^tz([a-z]{3}) ]]; then
    iata="${BASH_REMATCH[1]}"
  else
    log "$LOG_WARN" "YouTube CDN: unknown mapping name '$name'"
  fi
  iata=${iata^^}

  if [[ -z "$iata" ]]; then
    echo ""
    return
  fi

  location=$(get_iata_location "$iata")
  echo "$location"
}

lookup_netflix_cdn() {
  local ip_version="$1"
  local response

  # TODO: Make contant
  response=$(make_request GET "https://api.fast.com/netflix/speedtest/v2?https=true&token=YXNkZmFzZGxmbnNkYWZoYXNkZmhrYWxm&urlCount=1" --ip-version "$ip_version")

  if is_valid_json "$response"; then
    process_json "$response" ".targets[0].location.country"
  else
    echo ""
  fi
}

lookup_ookla_speedtest() {
  local ip_version="$1"
  local response

  response=$(make_request GET "https://www.speedtest.net/api/js/config-sdk" --ip-version "$ip_version")
  process_json "$response" ".location.countryCode"
}

lookup_jetbrains() {
  local ip_version="$1"
  local response

  response=$(make_request GET "https://data.services.jetbrains.com/geo" --ip-version "$ip_version")
  process_json "$response" ".code"
}

lookup_playstation() {
  local ip_version="$1"
  local tmpresult

  tmpresult=$(make_request HEAD "https://www.playstation.com" --ip-version "$ip_version" --user-agent "$USER_AGENT")

  echo "$tmpresult" | grep -i 'Set-Cookie: country=' | head -n1 | sed 's/.*country=\([A-Z]*\).*/\1/'
}

check_doh() {
    local test_domain="www.google.com"

    local resolvers=(
        "Cloudflare|https://1.1.1.1/dns-query|https://1.1.1.1/dns-query"
        "Quad9|https://9.9.9.9/dns-query|https://9.9.9.9/dns-query"
        "OpenDNS|https://208.67.222.222/dns-query|https://208.67.222.222/dns-query"
        "AdGuard|https://94.140.14.140/dns-query|https://94.140.14.140/dns-query"
    )

    local curl_opts=(-s --max-time 5 --connect-timeout 2 -o /dev/null)

    local entry name doh_url

    SELECTED_DOH_ARGS=()

    # With a SOCKS5 proxy the proxy resolves names itself (socks5h), DoH is not needed
    if [[ -n "$PROXY_ADDR" ]]; then
        return 0
    fi

    if [[ -n "$INTERFACE_NAME" ]]; then
        curl_opts+=(--interface "$INTERFACE_NAME")
    fi

    for entry in "${resolvers[@]}"; do
        IFS="|" read -r name doh_url _ <<<"$entry"

        if curl "${curl_opts[@]}" --doh-url "$doh_url" "https://$test_domain/" 2>/dev/null; then
            log "$LOG_INFO" "Using DoH resolver: $name"
            SELECTED_DOH_ARGS=(--doh-url "$doh_url")
            return 0
        fi
    done

    return 1
}

# Чужой IP: подставляем его вместо внешнего адреса машины. Сервисы, которые смотрят на само
# соединение (Cloudflare, MaxMind /me, 2ip, DNS-резолвер), для него не имеют смысла
setup_target_mode() {
  if [[ "$TARGET_IP" == *:* ]]; then
    EXTERNAL_IPV6="$TARGET_IP"
    IPV6_ONLY=true
    IPV4_ONLY=false
    IPV6_SUPPORTED=0
  else
    EXTERNAL_IPV4="$TARGET_IP"
    IPV4_ONLY=true
    IPV6_ONLY=false
    IPV6_SUPPORTED=1
  fi

  GROUPS_TO_SHOW="target"
  EXCLUDED_SERVICES+=(CLOUDFLARE MAXMIND 2IP DNS_RESOLVER)
  log "$LOG_INFO" "Target IP mode: $TARGET_IP"
}

main() {
  parse_arguments "$@"

  install_dependencies
  [[ "$USE_DOH" == true ]] && check_doh

  if [[ -n "$TARGET_IP" ]]; then
    setup_target_mode
  else
    check_ip_support 4

    check_ip_support 6
    IPV6_SUPPORTED=$?

    get_external_ip
  fi

  if [[ -z "$EXTERNAL_IPV4" && -z "$EXTERNAL_IPV6" ]]; then
    error_exit "Не удалось определить внешний IP (нет интернета?). Можно указать IP аргументом: ./ipregion-lucx.sh 1.2.3.4"
  fi

  get_asn
  start_update_check

  if [[ "$JSON_OUTPUT" != true && "$VERBOSE" != true && "$INTERACTIVE" == true ]]; then
    trap 'spinner_stop; exit' INT TERM
    spinner_start
  fi

  case "$GROUPS_TO_SHOW" in
    custom | primary | cdn | network)
      run_service_groups "$GROUPS_TO_SHOW"
      ;;
    target)
      run_service_groups primary network
      ;;
    *)
      run_service_groups custom primary cdn network
      ;;
  esac

  if [[ "$JSON_OUTPUT" != true && "$VERBOSE" != true && "$INTERACTIVE" == true ]]; then
    spinner_stop
    trap - INT TERM
  fi

  print_results
  print_verdict
  exit "$VERDICT_EXIT"
}

main "$@"
