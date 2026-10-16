/*
 * main.m — the entry point: make the application, start the desktop, pump.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 *
 *   Workspace [--seconds N]
 *
 * The `--seconds` is a TEST'S door and is named as one: a desktop is a thing that stays, and the suite needs it
 * to be able to leave. Later stages replace it with the ordinary run loop.
 */
#import <AppKit/NSApplication.h>
#import <Foundation/NSAutoreleasePool.h>

#import "WSApplication.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
	double seconds = 3.0;
	WSApplication *workspace;
	int i;

	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--seconds") == 0 && i + 1 < argc) {
			seconds = atof(argv[++i]);
		} else {
			fprintf(stderr, "usage: %s [--seconds N]\n", argv[0]);
			return 2;
		}
	}

	@autoreleasepool {
		NSApplication *application = [NSApplication sharedApplication];

		[application finishLaunching];

		workspace = [[WSApplication alloc] init];
		if (![workspace start]) {
			fprintf(stderr, "workspace: THE DESKTOP WINDOW WAS NOT MADE\n");
			return 1;
		}
		[workspace runForSeconds:seconds];
		[workspace stop];
		[workspace release];
	}
	return 0;
}
