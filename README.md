# iNat-GB-Name

A tool to detect taxonomic name discrepancies between iNaturalist observations and GenBank accession records.

## Overview

This script compares taxonomic names between iNaturalist observations and their linked GenBank sequences. It identifies and reports when names differ, helping to maintain taxonomic consistency across platforms.

The tool checks:
1. The consensus name on iNaturalist
2. The "Provisional Species Name" observation field on iNaturalist (if available)
3. The taxonomic name in the GenBank record

## Requirements

- Perl
- The following Perl modules:
  - LWP (for HTTPS requests)
  - BioPerl
  - JSON
  - Time::HiRes
  - Getopt::Long

### Installation

On Ubuntu/Debian systems:
```bash
sudo apt-get install liblwp-protocol-https-perl bioperl libjson-perl
sudo cpan Bio::DB::GenBank
```

## Usage

### Basic Usage
```bash
./inat-gb-name.pl <observation_number>
```

### Process Multiple Observations
```bash
./inat-gb-name.pl -f <filename>
```
Where the file contains one or more iNaturalist observation IDs, separated by spaces, commas, or newlines.

### Command Line Options

- `-v`, `--verbose`: Enable verbose output with additional details
- `-q`, `--quiet`: Suppress certain non-critical error messages
- `-f`, `--file`: Specify a file containing observation IDs to process

## Examples

### Check a Single Observation
```bash
./inat-gb-name.pl 232615678
```

### Process Multiple Observations with Detailed Output
```bash
./inat-gb-name.pl -v -f observation_list.txt
```

### Process Observations Quietly (Minimal Output)
```bash
./inat-gb-name.pl -q -f observation_list.txt
```

## Output Format

When mismatches are found, the script outputs a tab-separated list with:
```
iNat #          Genbank Name                    iNaturalist Name
232615678       Amanita sp. 'sp-S19'            Amanita sp. 'S19'
```

## How It Works

1. **Data Retrieval**: 
   - Fetches observation data from the iNaturalist API
   - Retrieves observation fields to find the GenBank accession number
   - Queries GenBank for the sequence information and taxonomic name

2. **Name Normalization**:
   - Standardizes taxonomic names by handling variations in species designations
   - Accounts for different formats of "sp." notation
   - Removes special characters while preserving meaningful distinctions

3. **Comparison**:
   - Compares normalized names to detect true differences
   - Prioritizes the "Provisional Species Name" field if available
   - Falls back to the consensus iNaturalist name otherwise

4. **Batch Processing**:
   - Processes observations in batches of up to 200 at a time
   - Uses the iNaturalist API's pagination feature to minimize API calls
   - Implements rate limiting to prevent exceeding API limits

## API Rate Limiting

The script enforces a minimum 1-second delay between API requests to respect iNaturalist's limits of:
- 60 requests per minute
- 10,000 requests per day

In verbose mode it will let you know how many API requests it made.

## Notes

- For observations without a valid GenBank Accession Number, an error message will be displayed unless quiet mode is enabled
- Time estimates are provided when processing 10 or more observations
- Verbose mode is really good for debugging, and gives a summary of API usage.

## Exception List

The script contains an exception list for known taxonomic discrepancies that should not be reported. Edit the `%exceptions` hash in the code to add your own exceptions.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history and details about updates.

## License

This tool was created by Alan Rockefeller and is provided under the The GNU General Public License v3.0

## Contributing

Contributions are welcome! Please feel free to submit pull requests or create issues for bugs and feature requests.   Or contact me on IG / FB / LinkedIn / email.
