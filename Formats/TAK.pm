package Plugins::PlayTAK::Formats::TAK;

# TAK is not supported by Audio::Scan. The APEv2 tags are read by scanning the
# file as mp3 (which also reads APEv2 tags), the audio properties come from
# ffprobe. An external album id is set from the Discogs release id so that
# different releases of the same album / artist are not merged into one album.

use strict;
use warnings;
use base qw(Slim::Formats);

use Audio::Scan;
use JSON::XS qw(decode_json);

use Slim::Formats::APE;
use Slim::Utils::Log;
use Slim::Utils::Misc;

my $log = logger('plugin.playtak');

# Applied on top of the core APE mapping (Slim::Formats::APE::doTagMapping).
# A mapping never overwrites a value that is already present.
my %tagMapping = (
    'ALBUM_ARTIST'      => 'ALBUMARTIST',
    'ALBUM ARTIST SORT' => 'ALBUMARTISTSORT',
    'ALBUMARTIST_SORT'  => 'ALBUMARTISTSORT',
    'UNSYNCEDLYRICS'    => 'LYRICS',
    'UNSYNCED LYRICS'   => 'LYRICS',
    'RELEASEDATE'       => 'YEAR',
);

# Normalized names (upper case, letters and digits only) of the tags holding
# the Discogs release id, in order of preference.
my @extIdNames = qw(DISCOGSRELEASEID DISCOGSID DISCOGSRELEASE);

# Names under which taggers store the disc number, the number of discs and the
# disc title, in order of preference. Core only knows DISCNUMBER and DISCSUBTITLE.
my @discNumberKeys = ('DISCNUMBER', 'DISC', 'DISC NUMBER', 'DISC_NUMBER');
my @discTotalKeys  = ('DISCTOTAL', 'TOTALDISCS', 'DISC_TOTAL', 'DISC TOTAL', 'DISCC');
my @discTitleKeys  = (
    'DISCSUBTITLE', 'DISC SUBTITLE', 'DISC_SUBTITLE',
    'DISCTITLE', 'DISC TITLE', 'DISC_TITLE', 'SETSUBTITLE', 'SET SUBTITLE',
);

# Bit depth by ffprobe sample format.
my %sampleSize = (
    u8  => 8,  s16  => 16, s32  => 32, flt  => 32, dbl  => 64,
    u8p => 8,  s16p => 16, s32p => 32, fltp => 32, dblp => 64,
    s64 => 64, s64p => 64,
);

sub getTag {
    my ($class, $file, $anchor) = @_;
    return {} unless $file;

    my $probe = _probe($file) or return;

    my $format = $probe->{format} || {};
    my $stream = $probe->{streams} && $probe->{streams}->[0];
    my $secs   = $format->{duration} || ($stream && $stream->{duration});

    unless ($stream && $stream->{sample_rate} && $secs) {
        $log->warn("PlayTAK: no audio properties found for $file");
        return;
    }

    my $tags = _readApeTags($file);

    # ffprobe only fills the gaps
    my $probeTags = $format->{tags} || {};

    for my $key (keys %$probeTags) {
        my $value = $probeTags->{$key};
        next unless defined $value && length $value;

        $tags->{ uc $key } //= $value;
    }

    my $size = -s $file;

    $tags->{SIZE}         = $size;
    $tags->{OFFSET}       = 0;
    $tags->{SECS}         = $secs + 0;
    $tags->{RATE}         = $stream->{sample_rate} + 0;
    $tags->{CHANNELS}     = $stream->{channels} + 0 if $stream->{channels};
    $tags->{SAMPLESIZE}   = _sampleSize($stream);
    $tags->{BITRATE}      = int($stream->{bit_rate} || $format->{bit_rate} || $size * 8 / $tags->{SECS});
    $tags->{LOSSLESS}     = 1;
    $tags->{CONTENT_TYPE} = 'tak';

    main::DEBUGLOG && $log->is_debug && $log->debug("PlayTAK: raw disc tags of $file: " . _discTags($tags));

    # before the core mapping, which would overwrite DISC with DISCNUMBER
    $class->_mapDisc($tags);

    Slim::Formats::APE->doTagMapping($tags);

    $class->_mapExtraTags($tags);
    $class->_setExtId($tags);

    main::DEBUGLOG && $log->is_debug && $log->debug("PlayTAK: disc tags of $file: " . _discTags($tags));

    return $tags;
}

# Cover art from the APEv2 tag
sub getCoverArt {
    my ($class, $file) = @_;
    return unless $file;

    local $ENV{AUDIO_SCAN_NO_ARTWORK} = 0;

    return _readApeTags($file)->{'COVER ART (FRONT)'};
}

sub canSeek { 1 }

# APEv2 keys are case insensitive: work with upper case names only.
sub _readApeTags {
    my ($file) = @_;

    open my $fh, '<:raw', $file or do {
        $log->warn("PlayTAK: could not open $file: $!");
        return {};
    };

    my $s = eval { Audio::Scan->scan_fh(mp3 => $fh) };

    $log->warn("PlayTAK: Audio::Scan failed for $file: $@") if $@;

    close $fh;

    my $found = $s && $s->{tags} ? $s->{tags} : {};
    my %tags;

    for my $key (keys %$found) {
        $tags{ uc $key } //= $found->{$key};
    }

    return \%tags;
}

sub _probe {
    my ($file) = @_;

    my $ffprobe = Slim::Utils::Misc::findbin('ffprobe') || 'ffprobe';

    my @cmd = (
        $ffprobe, qw(-v quiet -print_format json -show_format -show_streams -select_streams a), $file,
    );

    unshift @cmd, '/usr/bin/timeout', '15' if -x '/usr/bin/timeout';

    open my $ph, '-|', @cmd or do {
        $log->warn("PlayTAK: could not run ffprobe for $file: $!");
        return;
    };

    my $json = do { local $/; <$ph> };

    close $ph;

    unless (defined $json && length $json) {
        $log->warn("PlayTAK: ffprobe returned nothing for $file");
        return;
    }

    my $probe = eval { decode_json($json) };

    unless ($probe) {
        $log->warn("PlayTAK: failed to decode ffprobe output for $file: $@");
        return;
    }

    return $probe;
}

sub _sampleSize {
    my ($stream) = @_;

    my $bits = $stream->{bits_per_raw_sample} || $stream->{bits_per_sample};

    return $bits + 0 if $bits;

    return $sampleSize{ $stream->{sample_fmt} // '' } || 16;
}

sub _mapExtraTags {
    my ($class, $tags) = @_;

    while (my ($old, $new) = each %tagMapping) {
        next unless exists $tags->{$old};

        my $value = delete $tags->{$old};
        $tags->{$new} = $value unless defined $tags->{$new};
    }

    # TRACK=3/12
    if (defined $tags->{TRACKNUM} && $tags->{TRACKNUM} =~ m{^\s*(\d+)\s*/}) {
        $tags->{TRACKNUM} = $1;
    }
}

# Sets DISC, DISCC and DISCSUBTITLE the way the server expects them: plain
# numbers (core drops anything else, and disc 0), first value only.
sub _mapDisc {
    my ($class, $tags) = @_;

    my $disc  = _takeFirst($tags, @discNumberKeys);
    my $discc = _takeFirst($tags, @discTotalKeys);
    my $title = _takeFirst($tags, @discTitleKeys);

    if (defined $disc) {
        # 1/2, 1-2, 1 of 2: a number of discs in its own tag wins
        if ($disc =~ m{(\d+)\s*(?:/|-|of)\s*(\d+)}i) {
            ($disc, $discc) = ($1, $discc // $2);
        }
        # Disc 2, 02
        elsif ($disc =~ /(\d+)/) {
            $disc = $1;
        }
        else {
            undef $disc;
        }
    }

    $discc = $1 if defined $discc && $discc =~ /(\d+)/;

    $tags->{DISC}         = $disc + 0  if $disc;
    $tags->{DISCC}        = $discc + 0 if $discc;
    $tags->{DISCSUBTITLE} = $title     if defined $title;
}

# Removes the tags and returns the first value that is not empty.
sub _takeFirst {
    my ($tags, @keys) = @_;

    my $found;

    for my $key (@keys) {
        next unless exists $tags->{$key};

        my $values = delete $tags->{$key};

        for my $value (ref $values eq 'ARRAY' ? @$values : $values) {
            next if !defined $value || ref $value;

            (my $trimmed = $value) =~ s/^\s+|\s+$//g;

            $found //= $trimmed if length $trimmed;
        }
    }

    return $found;
}

sub _discTags {
    my ($tags) = @_;

    return join ', ', map {
        my $value = $tags->{$_};
        "$_=" . (ref $value eq 'ARRAY' ? '[' . join('|', @$value) . ']' : $value // '');
    } sort grep { /DISC|^SET/ } keys %$tags;
}

sub _setExtId {
    my ($class, $tags) = @_;

    return if $tags->{ALBUM_EXTID};

    my %byName;

    for my $key (keys %$tags) {
        (my $name = uc $key) =~ s/[^A-Z0-9]//g;

        $byName{$name} //= $tags->{$key};
    }

    for my $name (@extIdNames) {
        my $value = $byName{$name};
        $value = $value->[0] if ref $value eq 'ARRAY';

        next if !defined $value || ref $value;

        $value =~ s/^\s+|\s+$//g;

        if (length $value) {
            $tags->{ALBUM_EXTID} = $value;
            return;
        }
    }
}

1;
