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
	int showAbout = 0;
	int showFileWindow = 0;
	int showListView = 0;

	/* **THE CHROME'S THEME, BEFORE THE FIRST WINDOW EXISTS.** `AGChromeTheme` resolves ONCE per process, and asking
	 * after a window has been made is asking for something already decided — so this comes before anything else.
	 *
	 * Without it Workspace draws the chrome's FALLBACK marks — flat grey circles — while the controls demonstration
	 * (which points `AGORA_CHROME_THEME` at the tree's `themes/`) draws the real thing, and a person looking at the
	 * About window asked why it had "the old stoplight controls". It did: it had no theme.
	 *
	 * The library's own default stays "no theme", which is right for a library — it must not go looking for other
	 * people's art. An APPLICATION is the other case, and this is the same arrangement `libagora-app`'s own
	 * demonstration uses: the build names the tree's directory, and an explicit `AGORA_CHROME_THEME` still wins. */
#ifdef AGORA_CHROME_DEFAULT_THEME
	if (getenv("AGORA_CHROME_THEME") == NULL) {
		setenv("AGORA_CHROME_THEME", AGORA_CHROME_DEFAULT_THEME, 1);
	}
#endif

	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--seconds") == 0 && i + 1 < argc) {
			seconds = atof(argv[++i]);
		} else if (strcmp(argv[i], "--list-view") == 0) {
			/* `--file-window` WITH W4'S LIST CHOSEN, for the same reason: a probe cannot click the switcher. */
			showFileWindow = 1;
			showListView = 1;
		} else if (strcmp(argv[i], "--file-window") == 0) {
			/* A TEST'S DOOR, for the same reason `--show-about` is one: a file window is otherwise reached by a
			 * menu action, and a probe cannot click. */
			showFileWindow = 1;
		} else if (strcmp(argv[i], "--show-about") == 0) {
			/* **A TEST'S DOOR, AND NAMED AS ONE.** The About panel is reached by a menu action, and a menu action
			 * needs a click — which is the one thing a probe of this tier cannot fake reliably (a synthetic click
			 * reaches the compositor's MOTION path and not its BUTTON path on this host). Opening it from here
			 * reproduces the same window creation, the same chrome and the same activation, on any display. */
			showAbout = 1;
		} else {
			fprintf(stderr, "usage: %s [--seconds N] [--show-about] [--file-window] [--list-view]\n", argv[0]);
			return 2;
		}
	}

	@autoreleasepool {
		NSApplication *application = [NSApplication sharedApplication];

		{
			const char *theme = getenv("AGORA_CHROME_THEME");

			fprintf(stderr, "workspace: chrome theme %s\n",
				(theme != NULL) ? theme : "none — drawing the fallback marks");
		}

		[application finishLaunching];

		workspace = [[WSApplication alloc] init];
		[workspace setShowsAboutOnStart:showAbout];
		[workspace setShowsFileWindowOnStart:showFileWindow];
		[workspace setFileWindowUsesListView:showListView];
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
