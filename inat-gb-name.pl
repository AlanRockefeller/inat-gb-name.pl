#!/usr/bin/perl

# inat-gb-name.pl version 2.0 by Alan Rockefeller (alanrockefeller at gmail)
# Last major update 2024-10-07 (refactored for robustness and maintainability)

# Usage: 
#   inat-gb-name.pl [-v] [-q] <inat observation number>
#   inat-gb-name.pl [-v] [-q] -f <filename>

# Requires LWP - on Ubuntu you can install it with "sudo apt-get install liblwp-protocol-https-perl"
# Requires bioperl - on Ubuntu you can install it with "sudo apt-get install bioperl"
# Requires json - on Ubuntu you can install it with "sudo apt-get install libjson-perl"
# You also may need to run "sudo cpan Bio::DB::GenBank" and set the PERL5LIB environment variable

# API rate limiting is implemented to limit requests to no more than 1 per second.
# The iNaturalist API allows up to 60 requests per minute and 10000 per day.

use strict;
use warnings;
use Time::HiRes qw(time sleep);
use LWP::UserAgent;
use JSON qw( decode_json );
use Bio::DB::GenBank;
use Data::Dumper;
use Getopt::Long;

# Global UserAgent for all HTTP requests
my $ua = LWP::UserAgent->new;
$ua->agent("inat-gb-name/2.0 (Perl; +https://github.com/alanrockefeller/inat-scripts)"); # Using a placeholder repo URL

my $verbose = 0;                   # Verbose output mode
my $quiet = 0;                     # Quiet mode to suppress some messages
my $file_mode = 0;                 # File input mode
my $input_file = "";               # Input file name
my $last_request_time = 0;         # Timestamp of the last API request
my @observations = ();             # Array to hold observation IDs
my $api_call_count = 0;            # Counter for API calls
my $mismatch_header_printed = 0;   # Flag to track if header was printed

# Parse command line arguments
GetOptions(
    "v|verbose" => \$verbose,
    "q|quiet" => \$quiet,
    "f|file=s" => \$input_file
) or die "Usage: $0 [-v] [-q] <inat observation number> OR $0 [-v] [-q] -f <filename>\n";

# Load exceptions from file if it exists
my %exceptions;
my $exceptions_file = "exceptions.txt";
if (-e $exceptions_file) {
    open(my $fh, '<', $exceptions_file) or warn "Could not open exceptions file '$exceptions_file': $!. Using empty exception list.\n";
    if ($fh) {
        while (my $line = <$fh>) {
            chomp $line;
            next if $line =~ /^\s*#|^\s*$/; # Skip comments and empty lines
            my ($id, $name) = split(/\t/, $line, 2);
            if ($id && $name && $id =~ /^\d+$/) {
                $exceptions{$id} = $name;
            } else {
                warn "Skipping malformed line in exceptions file: $line\n";
            }
        }
        close($fh);
        print "Loaded " . scalar(keys %exceptions) . " exceptions from '$exceptions_file'\n" if $verbose;
    }
} else {
    # TODO: Consider loading exceptions from an external file. (Kept for now if file doesn't exist)
    # Or, decide if the script should *only* use the file and have no hardcoded ones.
    # For now, if file not found, %exceptions remains empty.
    # %exceptions = (
    #     4750485 => "Dermocybe",
    #     84403644 => "Gymnopilus"
    # );
    print "Exceptions file '$exceptions_file' not found. Proceeding without pre-defined exceptions.\n" if $verbose || !$quiet;
}

# Function to rate limit API requests to at least 1 second apart
sub rate_limit {
    my $current_time = time();
    my $elapsed = $current_time - $last_request_time;
    
    if ($elapsed < 1) {
        sleep(1 - $elapsed);
    }
    
    $last_request_time = time();
    $api_call_count++;  # Increment the API call counter
}

# Function to normalize names for consistent comparison
sub normalize_name {
    my ($name) = @_;
    
    # Skip normalization if the name is undefined
    return "" unless defined $name;
    
    # Make a copy of the original
    my $normalized = $name;
    
    # Replace various forms of "sp." (sp-, sp., sp followed by space) with a single space.
    $normalized =~ s/(?:sp-|sp\.|sp\s+)/ /g;
    # Remove any character that is not a word character (alphanumeric) or whitespace.
    # This helps to strip away punctuation, symbols, etc.
    $normalized =~ s/[^\w\s]//g;
    # Remove "cf" (compare form) if it's surrounded by spaces, effectively treating "Genus cf. species" as "Genus species".
    $normalized =~ s/ cf / /g;
    # Remove "subsp" (subspecies indicator) if surrounded by spaces.
    $normalized =~ s/ subsp / /g;
    # Collapse multiple whitespace characters into a single space.
    $normalized =~ s/\s+/ /g;
    # Remove leading and trailing whitespace from the name.
    $normalized =~ s/^\s+|\s+$//g;
    
    return $normalized;
}

# Function to process observations in batches using pagination
sub process_observations_batch {
    my ($obs_batch) = @_;
    
    # Join observation IDs for the API call
    my $obs_ids = join(',', @$obs_batch);
    
    $ua->timeout(60); # Increased timeout for batch requests
    
    # Set the URL for the API endpoint with pagination parameters (up to 200 per page)
    my $url = "https://api.inaturalist.org/v1/observations?id=$obs_ids&per_page=200";
    print "Fetching batch of " . scalar(@$obs_batch) . " observations\n" if $verbose;
    
    # Apply rate limiting before making the request
    rate_limit();
    
    # Send an HTTP GET request to the API endpoint
    my $response = $ua->get($url);
    
    # Check the response status
    unless ($response->is_success) {
        # If fetching the batch fails, print error and skip this batch.
        print STDERR "Error: iNaturalist API request for batch observations (IDs: $obs_ids) failed with status: " . $response->status_line . "\n";
        print STDERR "Skipping processing for this batch.\n" if !$quiet;
        return;
    }
    
    # Parse the JSON response into a Perl data structure
    my $data;
    eval {
        $data = decode_json($response->content);
    };
    if ($@) {
        # If JSON decoding for the batch fails, print error and skip this batch.
        print STDERR "Error: Failed to decode JSON response from iNaturalist API for batch (IDs: $obs_ids). Error: $@\n";
        print STDERR "Skipping processing for this batch.\n" if !$quiet;
        return;
    }
    
    # Verify the structure of the response
    unless (defined $data && exists $data->{results} && ref($data->{results}) eq 'ARRAY') {
        print STDERR "Error: iNaturalist API response for batch (IDs: $obs_ids) is missing expected data structure (e.g., results array).\n";
        print STDERR "Skipping processing for this batch.\n" if !$quiet;
        return;
    }
    
    # Create a lookup hash of observation data by ID
    my %obs_data;
    foreach my $result (@{$data->{results}}) {
        my $current_obs_id = $result->{id} || "UNKNOWN_ID"; # Handle if ID itself is missing in a result
        
        if (defined $result->{taxon} && defined $result->{taxon}{name}) {
            $obs_data{$current_obs_id} = {
                taxon_name => $result->{taxon}{name}
            };
        } else {
            # Handle missing taxon name for an observation in the batch
            my $placeholder_name = "Unknown iNat Name";
            $obs_data{$current_obs_id} = {
                taxon_name => $placeholder_name
            };
            if ($verbose || !$quiet) {
                print STDERR "Warning: Missing taxon name for iNaturalist observation ID $current_obs_id in batch results. Using placeholder: '$placeholder_name'.\n";
            }
        }
    }
    
    # Now process each observation individually to get the observation fields
    # We iterate over original @$obs_batch to ensure we try to process all requested IDs
    foreach my $obs_id (@$obs_batch) {
        my $inat_species_name = "Unknown"; # Default if not found in batch response (should not happen if API is consistent)
        if (exists $obs_data{$obs_id} && defined $obs_data{$obs_id}{taxon_name}) {
            $inat_species_name = $obs_data{$obs_id}{taxon_name};
        } else {
             if ($verbose || !$quiet) {
                # This case implies the obs_id was in the request but not in the response's results, or ID was missing in a result.
                print STDERR "Warning: No taxon data returned in batch for observation ID $obs_id. Using default species name '$inat_species_name'.\n";
            }
        }
        # Pass mismatch_header_printed by reference
        process_single_observation($obs_id, $inat_species_name, \$mismatch_header_printed);
    }
}

# Function to process a single observation
sub process_single_observation {
    my ($observation_number, $inat_species, $mismatch_header_printed_ref) = @_;
    
    my $genbank_accession = "";
    my $provisional_name = "";
    
    $ua->timeout(30);
    
    # Set the URL for the API endpoint to get the iNat observation fields (using v1)
    my $url2 = "https://api.inaturalist.org/v1/observations/$observation_number"; # Changed to v1
    
    # Apply rate limiting before making the request
    rate_limit();
    
    # Send an HTTP GET request to the API endpoint for the iNat observation fields
    my $response2 = $ua->get($url2);
    
    unless ($response2->is_success) {
        print STDERR "Error: iNaturalist API request for single observation details (ID: $observation_number) failed. Status: " . $response2->status_line . "\n";
        print STDERR "Skipping observation $observation_number.\n" if !$quiet;
        return;
    }
    
    my $data;
    eval {
        $data = decode_json($response2->content);
    };
    if ($@) {
        print STDERR "Error: Failed to decode JSON response for iNaturalist observation ID $observation_number. Error: $@";
        print STDERR "Skipping observation $observation_number.\n" if !$quiet;
        return;
    }
    
    # Verify we have observation field values before trying to process them
    # For the v1 endpoint /observations/{id}, fields are directly in results[0].observation_field_values
    my $observation_details = $data; # Default to the whole response for the old endpoint
    if (exists $data->{results} && ref($data->{results}) eq 'ARRAY' && @{$data->{results}} > 0) {
        $observation_details = $data->{results}[0]; # Adjust for v1 structure where single observation is in results array
    }

    if (defined $observation_details && exists $observation_details->{'observation_field_values'}) {
        my $fields = $observation_details->{'observation_field_values'};
    
        # Store the Genbank Accession Number and Provisional Species Name observation fields
        foreach my $field (@$fields) {
            if (defined $field->{'observation_field'} && 
                defined $field->{'observation_field'}->{'name'}) {
                
                if ($field->{'observation_field'}->{'name'} eq 'Genbank Accession Number') {
                    $genbank_accession = $field->{'value'};
                }
                if ($field->{'observation_field'}->{'name'} eq 'Provisional Species Name') {
                    $provisional_name = $field->{'value'};
                }
            }
        }
    }
    else {
        print STDERR "Warning: No 'observation_field_values' found for iNaturalist observation ID $observation_number.\n";
        print STDERR "Skipping GenBank check for observation $observation_number.\n" if !$quiet;
        return;
    }
    
    # Check for valid Genbank Accession Number
    unless (defined $genbank_accession && $genbank_accession =~ /^[a-zA-Z0-9_]+$/) {
        if ($verbose || !$quiet) {
            # This message is already quite specific and good.
            print STDERR "iNaturalist observation ID $observation_number does not have a valid Genbank Accession Number observation field (found: '$genbank_accession').\n";
        }
        print STDERR "Skipping GenBank check for observation $observation_number.\n" if !$quiet;
        return;
    }
    
    # Apply rate limiting before making the GenBank request
    rate_limit();
    
    # Get the data from Genbank
    my $gb = Bio::DB::GenBank->new();
    my $seq;
    eval {
        $seq = $gb->get_Seq_by_acc("$genbank_accession");
    };
    if ($@) {
        my $error_msg = $@;
        chomp $error_msg;
        if ($error_msg =~ /couldn't connect to/i) {
            print STDERR "Error: Could not connect to GenBank for accession $genbank_accession (iNat Obs ID: $observation_number). Please check internet connection. Detail: $error_msg\n";
        }
        elsif ($error_msg =~ /failed to retrieve sequence/i) { # Simplified this condition
            print STDERR "Error: Failed to retrieve sequence from GenBank for accession $genbank_accession (iNat Obs ID: $observation_number). Accession may be invalid or unavailable. Detail: $error_msg\n";
        }
        else {
            print STDERR "Error: GenBank lookup failed for accession $genbank_accession (iNat Obs ID: $observation_number). Detail: $error_msg\n";
        }
        print STDERR "Skipping GenBank processing for observation $observation_number.\n" if !$quiet;
        return;
    }
    
    unless (defined $seq) {
        print STDERR "Error: Failed to retrieve sequence object from GenBank for accession $genbank_accession (iNat Obs ID: $observation_number) for an unknown reason (Bio::DB::GenBank returned undef).\n";
        print STDERR "Skipping GenBank processing for observation $observation_number.\n" if !$quiet;
        return;
    }
    
    my $species = $seq->species();
    unless (defined $species) {
        print STDERR "Error: Failed to retrieve species object from GenBank sequence for accession $genbank_accession (iNat Obs ID: $observation_number).\n";
        print STDERR "Skipping GenBank processing for observation $observation_number.\n" if !$quiet;
        return;
    }
    
    # Get the species name from the Bio::Species object
    my $genbank_name = "";
    if (eval { $species->can('scientific_name') } && defined $species->scientific_name) {
        $genbank_name = $species->scientific_name;
    } 
    # Fallback if scientific_name is not available or not defined, try genus and species_epithet
    elsif (eval { $species->can('genus') } && eval { $species->can('species_epithet') } &&
             defined $species->genus && defined $species->species_epithet) {
        $genbank_name = $species->genus . " " . $species->species_epithet;
    }
    # Basic fallback to classification if available and other methods fail
    elsif (eval { $species->can('classification') } && defined $species->classification) {
        my @classification = @{$species->classification};
        if (@classification) {
            $genbank_name = $classification[0]; # Safest bet is the first element
            print STDERR "Warning: Using first element of classification ('$genbank_name') as GenBank name for acc $genbank_accession (obs $observation_number) due to missing specific name fields.\n" if $verbose || !$quiet;
        }
    }

    unless ($genbank_name) {
        print STDERR "Warning: Could not retrieve a valid GenBank species name for accession $genbank_accession (iNat Obs ID: $observation_number).\n" if $verbose || !$quiet;
        # $genbank_name is already "", so we can just proceed.
        # The script will still attempt to compare, potentially matching an empty provisional name or iNat name if they also become empty after normalization.
    }
    
    print "Observation $observation_number (iNat Name: '$inat_species') has GenBank Acc: $genbank_accession, GenBank Name: '$genbank_name'\n" if $verbose && $genbank_name;
    print "Observation $observation_number (iNat Name: '$inat_species') has GenBank Acc: $genbank_accession, but GenBank Name could not be determined.\n" if $verbose && !$genbank_name;
    print "The Genbank number is $genbank_accession and the species on Genbank is '$genbank_name'\n" if $verbose && $genbank_name;
    
    # Format provisional name consistently so it can be compared
    if ($provisional_name) {
        print "Provisional species name on iNaturalist is '$provisional_name'\n" if $verbose;
        
        # Save original for display purposes
        my $display_provisional = $provisional_name;
        
        # For comparison, normalize the provisional name
        $provisional_name = normalize_name($provisional_name);
    }
    
    # Format $genbank_name consistently so it can be compared
    my $display_genbank = $genbank_name;  # Save original for display
    $genbank_name = normalize_name($genbank_name);
    
    # Handle cf. removal based on iNat species structure
    if ($inat_species !~ /\s/) {
       print "Removing cf. and everything after it in the Genbank name because the iNaturalist name is at genus level.\n" if ($verbose && $genbank_name =~ /\b(cf)\s+.+/ );
       $genbank_name =~ s/\b(cf)\s+.+//g;
    }
    
    # Normalize the iNat species name for consistent comparison
    my $normalized_inat_species = normalize_name($inat_species);
    
    # Process exception list
    if (exists $exceptions{$observation_number} && $exceptions{$observation_number} eq $inat_species) {
        print "Exception list activated for observation $observation_number - '$genbank_name' is different from '$inat_species'\n" if $verbose;
        return;
    }
    
    # If a provisional name exists, use it for comparison. If not, compare with the iNaturalist consensus name
    if ($provisional_name) {
        print "Comparing provisional name '$provisional_name' with Genbank name '$genbank_name'\n" if $verbose;
        
        # Check if names match after normalization
        if ($provisional_name ne $genbank_name) {
            print "Warning: Inaturalist corrected provisional species name '$provisional_name' does not match corrected Genbank Species Name '$genbank_name' in observation # $observation_number\n" if $verbose;
            
            # For display purposes, format the names nicely
            my $display_prov = $provisional_name;
            if ($display_prov =~ /^(\S+)\s+(\S+)$/) {  # Simple genus+identifier format
                $display_prov = "$1 sp. '$2'";
            }
            
            # Print header if this is the first mismatch
            if (!$$mismatch_header_printed_ref) {
                printf "%-15s\t%-30s\t%-30s\n", "iNat #", "Genbank Name", "iNaturalist Name";
                $$mismatch_header_printed_ref = 1;
            }
            
            # Use printf for consistent column alignment
            printf "%-15s\t%-30s\t%-30s\n", $observation_number, $display_genbank, $display_prov;
        }
    } else {
        print "Comparing iNaturalist consensus name '$normalized_inat_species' with Genbank name '$genbank_name'\n" if $verbose;
        if ($normalized_inat_species ne $genbank_name) {
            print "Warning: Inaturalist species name '$inat_species' does not match corrected Genbank Species Name '$genbank_name' in observation # $observation_number\n" if $verbose;
            
            # Print header if this is the first mismatch
            if (!$$mismatch_header_printed_ref) {
                printf "%-15s\t%-30s\t%-30s\n", "iNat #", "Genbank Name", "iNaturalist Name";
                $$mismatch_header_printed_ref = 1;
            }
            
            # Use printf for consistent column alignment
            printf "%-15s\t%-30s\t%-30s\n", $observation_number, $display_genbank, $inat_species;
        }
    }
}

# Read observations from a file if in file mode
if ($input_file) {
    open(my $fh, '<', $input_file) or die "Cannot open file '$input_file': $!\n";
    while (my $line = <$fh>) {
        chomp $line;
        # Split by any combination of spaces, commas, and newlines
        my @ids = split(/[\s,]+/, $line);
        push @observations, grep { $_ =~ /^\d+$/ } @ids;
    }
    close($fh);
    
    if (@observations == 0) {
        die "No valid observation IDs found in file '$input_file'\n";
    }
    
    print "Found " . scalar(@observations) . " observation IDs in file\n" if $verbose;
} else {
    # Get the observation number from the command line argument
    my $observation_number = shift @ARGV;
    
    # Check if we have a valid observation number
    unless (defined $observation_number && $observation_number =~ /^\d+$/) {
        die "Usage: $0 [-v] [-q] <inat observation number> OR $0 [-v] [-q] -f <filename>\n";
    }
    
    push @observations, $observation_number;
}

# Display time estimate if processing 10+ observations and not in quiet mode
if (scalar(@observations) >= 10 && !$quiet) {
    my $estimated_seconds = scalar(@observations) * 2.7;
    my $minutes = int($estimated_seconds / 60);
    my $seconds = int($estimated_seconds % 60);
    
    my $time_str = "";
    if ($minutes > 0) {
        $time_str .= "$minutes minute" . ($minutes > 1 ? "s" : "");
        if ($seconds > 0) {
            $time_str .= " and ";
        }
    }
    if ($seconds > 0 || $minutes == 0) {
        $time_str .= "$seconds second" . ($seconds != 1 ? "s" : "");
    }
    
    print STDERR "Processing " . scalar(@observations) . " observations. Estimated time: $time_str\n";
}

# Process observations in batches of up to 200 (maximum allowed by the API)
my @current_batch;
my $batch_size = 0;
my $max_batch_size = 200;

foreach my $obs_id (@observations) {
    push @current_batch, $obs_id;
    $batch_size++;
    
    # Process batch when it reaches maximum size or at the end of the list
    if ($batch_size == $max_batch_size || $obs_id == $observations[-1]) {
        process_observations_batch(\@current_batch);
        @current_batch = ();
        $batch_size = 0;
    }
}

# Print API call statistics if in verbose mode
if ($verbose) {
    print "\n=== Summary ===\n";
    print "Total API calls made: $api_call_count\n";
    print "Total observations processed: " . scalar(@observations) . "\n";
    print "Average API calls per observation: " . sprintf("%.2f", $api_call_count / (scalar(@observations) || 1)) . "\n";
}

exit 0;
