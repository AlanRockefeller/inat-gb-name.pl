#!/usr/bin/perl

# inat-gb-name.pl version 2.0 by Alan Rockefeller (alanrockefeller at gmail)
# Last update 3/29/2025 (with optimized batch processing)

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

# Exception list - both the observation number and the iNat name are here because
# if the iNat name changes we want to be notified about these observations
my %exceptions = (
    # iNat has this as Cortinarius sect. Sanguinei and Genbank just as Cortinarius
    4750485 => "Dermocybe",
    # Gymnopilus on iNat, Gymnopilus sp. 'Albogymnopilus nanus' on Genbank
    84403644 => "Gymnopilus"
);

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
    
    # Handle "sp." and similar patterns
    $normalized =~ s/(?:sp-|sp\.|sp\s+)/ /g;  # Replace sp-, sp., sp+space with a space
    $normalized =~ s/[^\w\s]//g;              # Remove non-alphanumeric and non-space characters
    $normalized =~ s/ cf / /g;                # Remove cf if it's by itself
    $normalized =~ s/ subsp / /g;             # Remove subsp.
    $normalized =~ s/\s+/ /g;                 # Replace multiple spaces with a single space
    $normalized =~ s/^\s+|\s+$//g;            # Remove leading/trailing whitespace
    
    return $normalized;
}

# Function to process observations in batches using pagination
sub process_observations_batch {
    my ($obs_batch) = @_;
    
    # Join observation IDs for the API call
    my $obs_ids = join(',', @$obs_batch);
    
    # Create a UserAgent object to send HTTP requests
    my $ua = LWP::UserAgent->new;
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
        die "Error: API request for batch observations failed with status " . $response->status_line . "\n";
    }
    
    # Parse the JSON response into a Perl data structure
    my $data;
    eval {
        $data = decode_json($response->content);
    };
    if ($@) {
        die "Error: Failed to decode JSON response from iNaturalist API: $@\n";
    }
    
    # Verify the structure of the response
    unless (defined $data && exists $data->{results}) {
        die "Error: iNaturalist API response is missing expected data structure\n";
    }
    
    # Create a lookup hash of observation data by ID
    my %obs_data;
    foreach my $result (@{$data->{results}}) {
        if (defined $result->{id} && defined $result->{taxon} && defined $result->{taxon}{name}) {
            $obs_data{$result->{id}} = {
                taxon_name => $result->{taxon}{name}
            };
        }
    }
    
    # Now process each observation individually to get the observation fields
    foreach my $obs_id (@$obs_batch) {
        process_single_observation($obs_id, $obs_data{$obs_id}{taxon_name} || "Unknown");
    }
}

# Function to process a single observation
sub process_single_observation {
    my ($observation_number, $inat_species) = @_;
    
    my $genbank_accession = "";
    my $provisional_name = "";
    
    # Create a UserAgent object if needed
    my $ua = LWP::UserAgent->new;
    $ua->timeout(30);
    
    # Set the URL for the API endpoint to get the iNat observation fields
    my $url2 = "https://www.inaturalist.org/observations/$observation_number.json";
    
    # Apply rate limiting before making the request
    rate_limit();
    
    # Send an HTTP GET request to the API endpoint for the iNat observation fields
    my $response2 = $ua->get($url2);
    
    unless ($response2->is_success) {
        print STDERR "Error: API request for observation fields failed with status " . $response2->status_line . " for observation $observation_number\n";
        return;
    }
    
    my $data;
    eval {
        $data = decode_json($response2->content);
    };
    if ($@) {
        print STDERR "Error: Failed to decode JSON response for observation fields: $@ for observation $observation_number\n";
        return;
    }
    
    # Verify we have observation field values before trying to process them
    if (defined $data && exists $data->{'observation_field_values'}) {
        my $fields = $data->{'observation_field_values'};
    
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
        print STDERR "Warning: No observation field values found for observation $observation_number\n";
        return;
    }
    
    # Check for valid Genbank Accession Number
    unless (defined $genbank_accession && $genbank_accession =~ /^[a-zA-Z0-9_]+$/) {
        # Only print the message if in verbose mode or not in quiet mode
        if ($verbose || !$quiet) {
            print STDERR "iNaturalist observation # $observation_number does not have a valid Genbank Accession Number observation field\n";
        }
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
        # Improved error handling for GenBank lookups
        if ($@ =~ /couldn't connect to/i) {
            print STDERR "Error: Could not connect to GenBank server for observation $observation_number. Please check your internet connection.\n";
        }
        elsif ($@ =~ /failed to retrieve sequence/i || $@ =~ /failed to retrieve sequence/i) {
            print STDERR "Error: Failed to retrieve sequence from GenBank for accession $genbank_accession (observation $observation_number). The accession number may be invalid or no longer available.\n";
        }
        else {
            print STDERR "Error: Failed to retrieve sequence from GenBank for accession $genbank_accession (observation $observation_number): $@\n";
        }
        return;
    }
    
    unless (defined $seq) {
        print STDERR "Error: Failed to retrieve sequence from GenBank for accession $genbank_accession (observation $observation_number, unknown reason)\n";
        return;
    }
    
    my $species = $seq->species();
    unless (defined $species) {
        print STDERR "Error: Failed to retrieve species information from GenBank for accession $genbank_accession (observation $observation_number)\n";
        return;
    }
    
    # Put the species info $info
    my $info = Dumper($species->classification);
    
    # Trim garbage from the Genbank name
    my @lines = split(/\n/, $info);
    my $genbank_name = $lines[0];
    $genbank_name =~ s/^\$VAR1 = '//;
    $genbank_name =~ s/\\//g;
    $genbank_name =~ s/\';$//;
    
    print "Observation $observation_number has a consensus name of '$inat_species' on iNaturalist\n" if $verbose;
    print "The Genbank number is $genbank_accession and the species on Genbank is '$genbank_name'\n" if $verbose;
    
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
            if (!$mismatch_header_printed) {
                printf "%-15s\t%-30s\t%-30s\n", "iNat #", "Genbank Name", "iNaturalist Name";
                $mismatch_header_printed = 1;
            }
            
            # Use printf for consistent column alignment
            printf "%-15s\t%-30s\t%-30s\n", $observation_number, $display_genbank, $display_prov;
        }
    } else {
        print "Comparing iNaturalist consensus name '$normalized_inat_species' with Genbank name '$genbank_name'\n" if $verbose;
        if ($normalized_inat_species ne $genbank_name) {
            print "Warning: Inaturalist species name '$inat_species' does not match corrected Genbank Species Name '$genbank_name' in observation # $observation_number\n" if $verbose;
            
            # Print header if this is the first mismatch
            if (!$mismatch_header_printed) {
                printf "%-15s\t%-30s\t%-30s\n", "iNat #", "Genbank Name", "iNaturalist Name";
                $mismatch_header_printed = 1;
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
