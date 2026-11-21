package Plugins::PlayTAK::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Plugins::PlayTAK::Register;

my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.playtak',
    defaultLevel => 'INFO',
    description  => 'PLUGIN_PLAYTAK',
});

sub initPlugin {
    my $class = shift;

    my $version = $class->_pluginDataFor('version') || 'unknown';
    $log->info("Initializing PlayTAK plugin $version");

    Plugins::PlayTAK::Register->registerFormatHandler();

    $class->SUPER::initPlugin(@_);
}

sub getDisplayName { 'PLUGIN_PLAYTAK' }

1;
