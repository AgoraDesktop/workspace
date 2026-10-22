/*
 * history — Back and Forward: the cursor, the stack, and what a new navigation does to the forward entries.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Portions of this file may derive from GNUstep; see THIRD-PARTY.md.
 *
 * Offscreen and Foundation-only: `WSHistory` is the arithmetic a file window's arrows ask, and none of it needs a
 * window. The cases are the reference file manager's: a new location truncates what was forward, the current
 * location is not a new entry, and a Back at the beginning does nothing.
 */
#import "WSHistory.h"

#import <Foundation/Foundation.h>

#include <stdio.h>

static int s_failed;

static void check(int ok, const char *name)
{
	printf("  %s   %s\n", ok ? "ok  " : "FAIL", name);
	if (!ok) {
		s_failed++;
	}
}

static NSURL *pathURL(NSString *path)
{
	return [NSURL fileURLWithPath:path];
}

int main(void)
{
	WSHistory *history = [[WSHistory alloc] initWithURL:pathURL(@"/A")];
	NSArray *urls;

	setvbuf(stdout, NULL, _IONBF, 0);

	check([[history currentURL] isEqual:pathURL(@"/A")], "the first location is current");
	check(![history canGoBack] && ![history canGoForward], "and neither arrow is possible");
	check([history backURL] == nil && [history forwardURL] == nil, "and neither names a URL");

	[history pushURL:pathURL(@"/B")];
	[history pushURL:pathURL(@"/C")];
	check([[history currentURL] isEqual:pathURL(@"/C")], "a push moves the cursor to the new location");
	check([history canGoBack] && ![history canGoForward], "and Back is possible where Forward is not");
	check([[history backURL] isEqual:pathURL(@"/B")], "Back names the previous location");

	check([history goBack] && [[history currentURL] isEqual:pathURL(@"/B")], "Back moves to /B");
	check([history canGoForward] && [[history forwardURL] isEqual:pathURL(@"/C")],
	      "and Forward now names /C");
	check([history goBack] && [[history currentURL] isEqual:pathURL(@"/A")], "a second Back reaches /A");
	check(![history canGoBack] && [history goBack] == NO, "and a Back at the beginning does nothing");

	check([history goForward] && [[history currentURL] isEqual:pathURL(@"/B")], "Forward returns to /B");
	[history pushURL:pathURL(@"/D")];
	check([[history currentURL] isEqual:pathURL(@"/D")] && ![history canGoForward],
	      "a new navigation from /B truncates the forward entry /C");

	urls = [history URLs];
	check([urls count] == 3
	      && [[urls objectAtIndex:0] isEqual:pathURL(@"/A")]
	      && [[urls objectAtIndex:1] isEqual:pathURL(@"/B")]
	      && [[urls objectAtIndex:2] isEqual:pathURL(@"/D")],
	      "the stack is /A, /B, /D and /C is gone");
	check([history currentIndex] == 2, "and the cursor is the last entry");

	[history pushURL:pathURL(@"/D")];
	check([[history URLs] count] == 3 && [history currentIndex] == 2,
	      "pushing the current location is a no-op, not a duplicate");

	[history release];
	printf("history: %s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
