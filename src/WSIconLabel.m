/*
 * WSIconLabel.m — the label's middle truncation, measured with the drawing attributes.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#import "WSIconLabel.h"

#import <AppKit/NSStringDrawing.h>

#import <Foundation/NSDictionary.h>

static NSString *fn_candidate(NSString *name, NSUInteger keep, NSString *ellipsis)
{
	NSUInteger length = [name length];
	NSUInteger prefix = (keep + 1) / 2;
	NSUInteger suffix = keep / 2;

	/* A middle cut keeps the head and the tail. The tail is what tells a `.txt` from a `.tar.gz`, and it is the
	 * half that a tail truncation loses. */
	return [NSString stringWithFormat:@"%@%@%@",
		[name substringToIndex:prefix], ellipsis,
		[name substringFromIndex:length - suffix]];
}

NSString *WSIconLabelText(NSString *name, CGFloat maxWidth, NSDictionary *attributes)
{
	static NSString *ellipsis = nil;
	NSUInteger length;
	NSUInteger low, high, best = 0;

	if (name == nil || [name length] == 0) {
		return @"";
	}
	if (maxWidth <= 0.0) {
		return @"";
	}
	if ([name sizeWithAttributes:attributes].width <= maxWidth) {
		return name;
	}
	if (ellipsis == nil) {
		ellipsis = [@"…" retain];
	}
	if ([ellipsis sizeWithAttributes:attributes].width > maxWidth) {
		return @"";
	}

	/* BINARY SEARCH OVER HOW MANY CHARACTERS SURVIVE THE CUT. Measuring is the cost and the answer is monotone,
	 * so a 200-character name takes eight measurements rather than two hundred. */
	length = [name length];
	low = 0;
	high = length;
	while (low <= high) {
		NSUInteger keep = (low + high) / 2;
		NSString *candidate = fn_candidate(name, keep, ellipsis);

		if ([candidate sizeWithAttributes:attributes].width <= maxWidth + 0.01) {
			best = keep;
			if (keep == length) {
				break;
			}
			low = keep + 1;
		} else {
			if (keep == 0) {
				break;
			}
			high = keep - 1;
		}
	}
	return fn_candidate(name, best, ellipsis);
}
