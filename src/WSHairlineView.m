/* Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#import "WSHairlineView.h"

@implementation WSHairlineView

- (BOOL)isOpaque
{
	return YES;
}

- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	[[NSColor controlDarkShadowColor] setFill];
	[[NSBezierPath bezierPathWithRect:[self bounds]] fill];
}

@end
