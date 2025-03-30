# Changelog

## Version 2.0 (March 29, 2025)

### Major Features
- **Batch Processing**: Added ability to process multiple observations from a file
- **API Pagination**: Implemented processing of up to 200 observations per API request to reduce API calls
- **Rate Limiting**: Added proper rate limiting to ensure requests are at least 1 second apart

### Command Line Options
- Added `-f` / `--file` option to specify an input file containing observation IDs
- Added `-q` / `--quiet` option to suppress certain messages
- Maintained backward compatibility with original single-observation mode

### Bug Fixes
- Fixed incorrect error handling reference for the second API request
- Added proper validation of API responses and JSON data structures
- Improved Genbank exception handling with more specific error messages
- Enhanced provisional name formatting to handle various formats (sp., sp-, sp)
- Added better validation for required fields

### Improvements
- **Name Comparison**: Completely redesigned name normalization logic
  - Fixed issues with species designations like "sp-S19" vs "sp. S19"
  - Improved handling of quotes, apostrophes, and special characters
  - Better pattern matching for taxonomic names
  - Preserved original names for display while normalizing for comparison
- **Formatted Output**: 
  - Improved column alignment with consistent widths
  - Added header row for mismatches for better readability
  - Better handling of long taxonomic names
- **Performance**:
  - Added time estimates for batch processing
  - Reduced redundant API calls through batch processing
  - Added API call statistics in verbose mode
- **Error Handling**:
  - Enhanced error messages with more specific details
  - Better exception handling for network and parsing issues
  - Added graceful continuation when individual observations fail

### Documentation
- Updated usage instructions to reflect new command line options
- Added more detailed comments throughout the code

## Version 1.4 (July 24, 2024)
- Original version by Alan Rockefeller
