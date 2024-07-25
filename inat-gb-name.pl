#!/usr/bin/perl

# inat-gb-name.pl version 1.4 by Alan Rockefeller (alanrockefeller at gmail)
# Last update 7/24/2024

# Usage: inat-gb-name.pl [-v] <inat observation number>

# Requires LWP - on Ubuntu you can install it with "sudo apt-get install liblwp-protocol-https-perl"
# Requires bioperl - on Ubuntu you can install it with "sudo apt-get install -y bioperl"
# Requires json - on Ubuntu you can install it with "sudo apt-get install libjson-perl"
# You also may need to run "sudo cpan Bio::DB::GenBank"

# You should add a delay if you are running large batches - the iNaturalist API instructions 
# request that you limit API calls to 60 per minute and 10000 per day, and this script makes 
# two iNaturalist API calls and one Genbank API call each time it runs.

# Todo: Fix handling of Genbank lookup failures, seen in iNat 152333880
# Get the full name if the iNaturalist name is below species level

use strict;
use warnings;

use LWP::UserAgent;
use JSON qw( decode_json );
use Bio::DB::GenBank;
use Data::Dumper;

my $verbose = 0;                   # Verbose output mode
my $genbank_accession = "";        # The Genbank accession number
my $provisional_name = "";         # The Provisional Species Name iNaturalist observation field


# Exception list - both the observation number and the iNat name are here because
# if the iNat name changes we want to be notified about these observations
my %exceptions = (
    # iNat has this as Cortinarius sect. Sanguinei and Genbank just as Cortinarius
    4750485 => "Dermocybe",
    # Gymnopilus on iNat, Gymnopilus sp. 'Albogymnopilus nanus' on Genbank
    84403644 => "Gymnopilus"
);

# Create a new instance of the Bio::DB::GenBank object
my $gb = Bio::DB::GenBank->new();

# Get the observation number from the command line argument
my $observation_number = shift @ARGV;

# Enable verbose mode if -v command line switch is given
if ($observation_number && $observation_number eq "-v") { 
    $verbose = 1; 
    $observation_number = shift @ARGV;
} 

# Make sure the observation number is numeric
unless (defined $observation_number && $observation_number =~ /^\d+$/) {
    die "Usage: $0 [-v] <inat observation number>\n\nNormally this script is silent unless it detects an issue - you can use the -v option to turn on verbose output.\n";
}

# Create a UserAgent object to send HTTP requests
my $ua = LWP::UserAgent->new;

# Set the URL for the API endpoint
my $url = "https://api.inaturalist.org/v1/observations/$observation_number";

# Send an HTTP GET request to the API endpoint for the iNat observation name
my $response = $ua->get($url);

# Check the response status
unless ($response->is_success) {
    die "Error: API request failed with status " . $response->status_line . "\n";
}

# Parse the JSON response into a Perl data structure
my $data = decode_json($response->content);

# Extract the iNaturalist species name from the data structure
my $inat_species =  $data->{results}[0]{taxon}{name};

# Set the URL for the API endpoint to get the iNat observation fields
my $url2 = "https://www.inaturalist.org/observations/$observation_number.json";

# Send an HTTP GET request to the API endpoint for the iNat observation fields
my $response2 = $ua->get($url2);

if ($response2->is_success) {
    my $data = decode_json($response2->content);
    my $fields = $data->{'observation_field_values'};

    # Store the Genbank Accession Number and Provisional Species Name observation fields
    foreach my $field (@$fields) {
        if ($field->{'observation_field'}->{'name'} eq 'Genbank Accession Number') {
	    $genbank_accession = $field->{'value'};
        }
        if ($field->{'observation_field'}->{'name'} eq 'Provisional Species Name') {
	    $provisional_name = $field->{'value'};
	    
        }
    }
}
else {
    die $response->status_line;
}

unless  ($genbank_accession =~ /^[a-zA-Z0-9_]+$/) {
        print STDERR "iNaturalist observation # $observation_number does not have a Genbank Accession Number observation field\n";
	exit(1);
}


# Get the data from Genbank
my $seq;
eval {
    $seq = $gb->get_Seq_by_acc("$genbank_accession");
};
if ($@) {
    die "Error: Failed to retrieve sequence from GenBank for accession $genbank_accession\n";
}
my $species = $seq->species();

# put the species info $info
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
    $provisional_name =~ s/sp-//;      # Remove sp- from Provisional Name
    $provisional_name =~ s/[^\w\s]//g; # Remove white space from Provisional Name
}

# Format $genbank_name consistently so it can be compared
$genbank_name =~ s/ sp\.\s*/ /;   # Remove sp.
$genbank_name =~ s/[^\w\s]//g;    # Remove non-alphanumeric characters
# Remove cf. and everything after it, but only if there is a genus and 
# species in the iNaturalist name.
if ($inat_species !~ /\s/) {
   print "Removing cf. and everything after it in the Genbank name because the iNaturalist name is at genus level.\n" if ($verbose && $genbank_name =~ /\b(cf)\s+.+/ );
   $genbank_name =~ s/\b(cf)\s+.+//g;
}
$genbank_name =~ s/ cf / /g;       # Remove cf if it's by itself
$genbank_name =~ s/ subsp / /;    # Remove subsp.
$genbank_name =~ s/\s+$//;        # Remove whitespace



# Process exception list
if (exists $exceptions{$observation_number} && $exceptions{$observation_number} eq $inat_species) {
    print "Exception list activated for observation $observation_number - '$genbank_name' is different from '$inat_species'\n" if $verbose;
    exit 0;
}


# If a provisional name exists, use it for comparison.  If not, compare with the iNaturalist consensus name
if ($provisional_name) {
    print "Comparing provisional name '$provisional_name' with Genbank name '$genbank_name'\n" if $verbose;
    if ($provisional_name ne $genbank_name) {
        print "Warning: Inaturalist corrected provisional species name '$provisional_name' does not match corrected Genbank Species Name '$genbank_name' in observation # $observation_number\n" if $verbose;
        # If the provisional name has a numerc code, format it for Genbank
	if ($provisional_name =~ /\d/) {
	    my $provisional_input = "$provisional_name";
	    $provisional_input =~ /^(\S+)\s+(.*)/;
	    $provisional_name = "$1 sp. '$2'";
	}
	print "$observation_number\t$genbank_name\t$provisional_name\n";
    }
} else {
    print "Comparing iNaturalist consensus name '$inat_species' with Genbank name '$genbank_name'\n" if $verbose;
    if ($inat_species ne $genbank_name) {
        print "Warning: Inaturalist species name '$inat_species' does not match corrected Genbank Species Name '$genbank_name' in observation # $observation_number\n" if $verbose;
	print "$observation_number\t$genbank_name\t$inat_species\n";
    }
}
