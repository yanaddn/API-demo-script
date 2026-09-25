# Working with API
Automated Bash script for normalizing and bulk-importing contacts from Excel files into API.

The `import_contacts.sh` script does the following:
- Normalizes and sanitizes phone numbers (removes `+`, spaces, hyphens, and brackets, leaving digits only).
- Validates required fields (Full Name and Phone Number).
- Splits large lists into batches (chunks) for safe API transmission.
- Handles network errors (timeouts) and server HTTP errors (4xx/5xx).
- Generates a detailed report and results log.

## 1. System Requirements & Installing Dependencies

The script relies on the following CLI utilities: `curl`, `jq`, `miller` (`mlr`), and `gnumeric` (`ssconvert` for Excel conversion).
### macOS (via Homebrew)
```bash
brew install gnumeric miller jq curl
```
### Ubuntu / Debian
```bash
sudo apt update
sudo apt install -y gnumeric miller jq curl
```
## 2. Environment Configuration
Copy the configuration template .env.example to .env:
```bash
cp .env.example .env
```
Open the .env file and set the URL and API access token:
```
COMPANY_URL=your_url_here
TOKEN=your_access_token_here
TYPE_ID=200
BATCH_SIZE=1000
```
## 3. Contact File Requirements

The input file can be in .xls or .xlsx format. The first row must contain column headers.

## 4. Usage & Execution
Make the script executable (run once before the first execution):
```bash
chmod +x import_contacts.sh
```
Standard import run:
```bash
./import_contacts.sh --file contacts.xlsx --queue-id 123
```
Upon completion, the script generates a detailed summary log.
