/*
 * WSSelectionBand.m — the wash and the hairline, in one place.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#import "WSSelectionBand.h"

#import <AppKit/NSBezierPath.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSGraphics.h>

void WSSelectionBandDraw(NSRect band)
{
	NSColor *accent = [NSColor cg_accentColor];
	NSColor *edge;

	if (accent == nil) {
		return;
	}
	if (band.size.width < WSSelectionBandMinimumExtent || band.size.height < WSSelectionBandMinimumExtent) {
		return;
	}
	/* **THE ACCENT IS THE WASH AND A DARKER SHADE OF IT IS THE EDGE.** `-shadowWithLevel:` walks a colour toward black,
	 * which is exactly "the same hue, darker"; a colour it cannot read as RGB answers nil, and then the edge is the accent
	 * itself rather than nothing — an outline that is too light still reads as an outline, and no outline reads as a bug. */
	edge = [accent shadowWithLevel:WSSelectionBandShadowLevel];
	if (edge == nil) {
		edge = accent;
	}
	[[accent colorWithAlphaComponent:WSSelectionBandFillAlpha] setFill];
	[NSBezierPath fillRect:band];

	[edge setStroke];
	[[NSBezierPath bezierPathWithRect:NSInsetRect(band, 0.5, 0.5)] stroke];
}
