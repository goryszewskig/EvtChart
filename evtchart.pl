#!/usr/bin/perl -w
#
# evtchart.pl	Convert an evt trace log into a SVG image (Gantt chart).
#
# Input data has the format:
#
# TIME(ns) EVENT ID ID_NAME PARENT_ID EXTRAS
#
# EVENT describes the event type, and is one of the following strings:
#
#	start		beginning of the event
#	end		end of the event
#	change		event changed; eg, new ID name
#
# Eg, for process event tracing the fields can be:
#
#	EVENT = "start", for fork()
#	EVENT = "change", for exec()
#	EVENT = "end", for exit()
#	ID = PID
#	ID_NAME = execname
#	PARENT_ID = PPID
#
# SEE ALSO:
#	procevt.d: a DTrace script to trace process execution as an evt log.
#
# HISTORY
#
# Gantt charts have been used for visualizing process execution for many years.
# See the Linux boot chart project: # http://www.bootchart.org/ 
# and the DTrace Python boot chart:
# http://alexeremin.blogspot.com/2009/01/boot-chart-with-help-of-dtrace-and.html
# both of which inspired this work.
#
# Copyright 2012 Joyent, Inc.  All rights reserved.
# Copyright 2012 Brendan Gregg.  All rights reserved.
#
# CDDL HEADER START                                                                                                                                          
#                                                                                                                                                            
# The contents of this file are subject to the terms of the                                                                                                  
# Common Development and Distribution License (the "License").                                                                                               
# You may not use this file except in compliance with the License.                                                                                           
#                                                                                                                                                            
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE                                                                                        
# or http://www.opensolaris.org/os/licensing.                                                                                                                
# See the License for the specific language governing permissions                                                                                            
# and limitations under the License.                                                                                                                         
#                                                                                                                                                            
# When distributing Covered Code, include this CDDL HEADER in each                                                                                           
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.                                                                                          
# If applicable, add the following below this CDDL HEADER, with the                                                                                          
# fields enclosed by brackets "[]" replaced with your own identifying                                                                                        
# information: Portions Copyright [yyyy] [name of copyright owner]                                                                                           
#                                                                                                                                                            
# CDDL HEADER END  
#
# 10-Sep-2011	Brendan Gregg	Created this.

use strict;
use POSIX qw(ceil);
$| = 1;

# tunables
my $outfile = "chart.svg";
my $fonttype = "Verdana";
my $imagewidth = 900;		# max width, pixels
my $eventheight = 13;		# height is dynamic
my $dotrunc = 1;		# compress short events

# internals
my $fontsize = 8;		# base text size
my $ypad = $fontsize * 2 + 30;	# pad top, include title and labels
my $xpadl = 10;			# pad left, include arrows
my $xpadr = 50;			# pad right, include titles
my $timezero = "";
my $timemax = 0;
my %Data;
my %Events;

# SVG functions

{ package SVG;
	sub new {
		my $class = shift;
		my $self = {};
		bless ($self, $class);
		return $self;
	}

	sub header {
		my ($self, $w, $h) = @_;
		$self->{svg} .= <<SVG;
<?xml version="1.0" standalone="no"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<svg version="1.1" width="$w" height="$h" onload="init(evt)" viewBox="0 0 $w $h" xmlns="http://www.w3.org/2000/svg" >
SVG
	}

	sub defs {
		my $self = shift;
		$self->{svg} .= <<SVG;
<defs >
	<linearGradient id="background" >
		<stop stop-color="#C5D5A9" offset="5%" />
		<stop stop-color="#eeeeee" offset="95%" />
	</linearGradient>
</defs>
SVG
	}

	sub colorAllocate {
		my ($self, $r, $g, $b) = @_;
		return "rgb($r,$g,$b)";
	}

	sub filledRectangle {
		my ($self, $x1, $y1, $x2, $y2, $fill, $stroke, $r) = @_;
		my $w = $x2 - $x1;
		my $h = $y2 - $y1;
		$r = defined $r ? $r : 0;
		$self->{svg} .= qq/<rect x="$x1" y="$y1" width="$w" height="$h" fill="$fill" stroke="$stroke" rx="$r" ry="$r" \/>\n/;
	}

	sub line {
		my ($self, $x1, $y1, $x2, $y2, $line) = @_;
		$self->{svg} .= qq/<line x1="$x1" y1="$y1" x2="$x2" y2="$y2" stroke="$line" stroke-width="1" \/>\n/;
	}

	sub stringTTF {
		my ($self, $color, $font, $size, $angle, $x, $y, $str) = @_;
		$self->{svg} .= qq/<text text-anchor="left" x="$x" y="$y" font-size="$size" font-family="$font" fill="$color" >$str<\/text>\n/;
	}

	sub setStyle {
	}

	sub svg {
		my $self = shift;
		$self->{svg} .= "</svg>\n";
		return $self->{svg};
	}
	1;
}

print "Timestamp sorting...\n";
while (<>) {
	chomp;
	my ($time, $data) = split(' ', $_, 2);
	next unless defined $time and $time =~ /^\d+$/;
	while (defined $Data{$time}) {
		# time(ns) should generally be unique; tweak when not
		$time += 0.01;
	}
	$Data{$time} = $data;
}

# Main

print "Parsing...\n";
foreach my $time (sort { $a <=> $b } keys %Data) {
	$timezero = $time if $timezero eq "";
	$timemax = $time if $time > $timemax;

	# TIME(ns) EVENT ID ID_NAME PARENT_ID EXTRAS
	my ($event, $id, $name, $parentid, $rest) = split ' ', $Data{$time};

	# change events can rename
	$Events{$id}->{name} = $name if $event eq "change";

	# first parent takes precedent (birth)
	$Events{$id}->{parent} = $parentid unless
	    defined $Events{$id}->{parent};

	if ($event eq "start") {
		$Events{$id}->{stime} = $time;
	} elsif ($event eq "change" and !defined $Events{$id}->{stime}) {
		# This should have been seen by now (time ordered),
		# unless it began before tracing.
		$Events{$id}->{stime} = $timezero;
	} elsif ($event eq "end") {
		$Events{$id}->{etime} = $time;
		unless (defined $Events{$id}->{stime}) {
			$Events{$id}->{stime} = $timezero;
		}
	}
}
my $secmax = ceil(($timemax - $timezero) / 1000000000);
my $widthpersec = (($imagewidth - $xpadl - $xpadr)) / $secmax;
my $widthperns = $widthpersec / 1000000000;

print "Calculating height...\n";
my $y1;
my $y2 = $ypad;
my $lastx = 0;
my $toosmallpx = 4;
my $toorecentpx = 8;
foreach my $id (sort { $Events{$a}->{stime} <=> $Events{$b}->{stime} } keys %Events) {
	my $x1 = $xpadl + int($widthperns * ($Events{$id}->{stime} - $timezero));
	my $x2 = defined $Events{$id}->{etime} ? $xpadl +
	    int($widthperns * ($Events{$id}->{etime} - $timezero)) : $imagewidth + 10;

	# truncate event if short duration and near last event, by making its
	# height 1 pixel and dropping the text. this compresses shell script loops.
	my $height = $eventheight;
	if ($dotrunc && (($x2 - $x1) < $toosmallpx && ($x2 - $lastx) < $toorecentpx)) {
		$height = 1;
		$Events{$id}->{trunc} = 1;
		$lastx = $x2;
		$x2++;
	} else {
		$lastx = $x2;
	}
	$y1 = $y2;
	$y2 = $y1 + $height;

	$Events{$id}->{x1} = $x1;
	$Events{$id}->{y1} = $y1;
	$Events{$id}->{x2} = $x2;
	$Events{$id}->{y2} = $y2;
}

print "Creating canvas...\n";
my $events = scalar keys %Events;
my $imageheight = $y2 + 2;
my $im = SVG->new();
$im->header($imagewidth, $imageheight);
my ($white, $black, $vvdgrey, $vdgrey, $dgrey, $grey, $lgrey, $red, $green, $blue) = (
	$im->colorAllocate(255, 255, 255),
	$im->colorAllocate(0, 0, 0),
	$im->colorAllocate(40, 40, 40),
	$im->colorAllocate(160, 160, 160),
	$im->colorAllocate(200, 200, 200),
	$im->colorAllocate(225, 225, 225),
	$im->colorAllocate(235, 235, 235),
	$im->colorAllocate(240, 180, 180),
	$im->colorAllocate(160, 220, 160),
	$im->colorAllocate(180, 180, 240)
    );
$im->stringTTF($black, $fonttype, $fontsize + 3, 0.0, 20, $fontsize + 6, "Event Time Chart") || die $@;

print "Drawing grid...\n";
for (my $i = 0; $i <= $secmax; $i++) {
	# Draw dark grey lines every 5 secs.
	# Optionally, draw grey lines every 1 and light grey lines every 0.1 sec;
	# these only appear if there is more than 10 pixels per target interval.
	my $columnspace = 10;
	my $x = $xpadl + int($i * $widthpersec);
	if (($i % 5) == 0) {
		$im->line($x, $ypad - 5, $x, $imageheight, $dgrey);
	} elsif ($widthpersec > $columnspace) {
		$im->line($x, $ypad - 5, $x, $imageheight, $grey);
	}
	if ($widthpersec > $columnspace * 10) {
		for (my $j = 1; $j < 10; $j++) {
			my $xj = $x + int($j * $widthpersec / 10);
			$im->line($xj, $ypad - 3, $xj, $imageheight, $lgrey);
		}
	}
	# Draw second labels on 5 sec lines, and 1 sec lines if 0.1 is present.
	if (($i % 5) == 0 || $widthpersec > $columnspace * 10) {
		$im->stringTTF($vvdgrey, $fonttype, $fontsize, 0.0, $x - 6, $ypad - 10,
		    "${i}s") || die $@;
	}
}

print "Drawing events...\n";
$y2 = $ypad;
$lastx = 0;
foreach my $id (sort { $Events{$a}->{stime} <=> $Events{$b}->{stime} } keys %Events) {
	my $x1 = $Events{$id}->{x1};
	my $y1 = $Events{$id}->{y1};
	my $x2 = $Events{$id}->{x2};
	my $y2 = $Events{$id}->{y2};

	# draw box and text
	my $border = defined $Events{$id}->{trunc} ? "$dgrey" : "$vdgrey";
	$im->filledRectangle($x1, $y1, $x2, $y2, $lgrey, $border, 4);
	unless (defined $Events{$id}->{trunc}) {
		my $name = defined $Events{$id}->{name} ? $Events{$id}->{name} : "";
		$im->stringTTF($vvdgrey, $fonttype, $fontsize, 0.0, $x1 + 5, $y1 + 2 + $fontsize, $name) || die $@;
	}
}

print "Drawing ancestory...\n";
$im->setStyle($blue, $blue, "transparent", "transparent");
foreach my $id (sort { $Events{$a}->{stime} <=> $Events{$b}->{stime} } keys %Events) {
	next if defined $Events{$id}->{trunc};
	next unless defined $Events{$id}->{parent};
	my $p_id = $Events{$id}->{parent};
	next unless defined $Events{$p_id};

	my $y1 = $Events{$p_id}->{y1} + $eventheight / 2;
	my $y2 = $Events{$id}->{y1} + $eventheight / 2;
	my $x1 = $Events{$p_id}->{x1};
	my $x2 = $Events{$id}->{x1};
	$im->line($x1 - 5, $y1, $x1 - 1, $y1, $blue);
	$im->line($x1 - 5, $y2, $x2 - 1, $y2, $blue);
	$im->line($x1 - 5, $y1, $x1 - 5, $y2, $blue);
}

print "Writing $outfile...\n";
open FILE, ">$outfile" or die "writing $outfile: $!";
print FILE $im->svg;
close FILE;
