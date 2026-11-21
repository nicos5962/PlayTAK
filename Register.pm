package Plugins::PlayTAK::Register;

# Registers the PlayTAK tag handler. Kept free of any web/UI dependency so it
# can be used by both the server plugin and the scanner importer.

use strict;
use warnings;

use Slim::Formats;
use Slim::Utils::Log;

use constant HANDLER => 'Plugins::PlayTAK::Formats::TAK';

my $log = logger('plugin.playtak');

sub registerFormatHandler {
    my ($class, $tagClasses) = @_;

    Slim::Formats->init();

    $tagClasses ||= \%Slim::Formats::tagClasses;

    return 0 unless ref($tagClasses) eq 'HASH';

    return 1 if defined $tagClasses->{tak} && $tagClasses->{tak} eq HANDLER;

    $tagClasses->{tak} = HANDLER;

    main::DEBUGLOG && $log->is_debug && $log->debug('PlayTAK: registered tak tag handler');

    return 1;
}

1;
