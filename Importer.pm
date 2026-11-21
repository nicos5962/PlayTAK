package Plugins::PlayTAK::Importer;

use strict;
use warnings;

use Plugins::PlayTAK::Register;

sub initPlugin {
    my $class = shift;

    Plugins::PlayTAK::Register->registerFormatHandler();
    return 1;
}

sub startScan {
    my $class = shift;
    return;
}

1;
