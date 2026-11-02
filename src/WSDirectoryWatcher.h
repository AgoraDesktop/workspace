/*
 * WSDirectoryWatcher.h — a window's ear on the filesystem.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **A FILE WINDOW SHOWS A DIRECTORY, AND THE DIRECTORY CHANGES WITHOUT BEING ASKED.** Until this existed, every view
 * in Workspace read its directory once and then never again: a folder made in a terminal, a file another application
 * moved, a download that finished — none of them appeared until a person navigated away and back. The `New Folder`
 * command refreshed only because the command itself told the window; anything else was invisible.
 *
 * `libagora-watch` is this tree's FSEvents (`WORKSPACE-PLAN.md` §2, F3), and this class asks it for the NON-RECURSIVE
 * form (a flag of ours, `kFSEventStreamCreateFlagNoRecursive`): one watch on the directory, no walk under it. A window
 * watches what it shows — a change inside a subfolder it is not listing cannot change a row it is drawing — and the
 * recursive form was measured as a freeze on a home directory. The stream coalesces a burst of changes into one
 * callback either way. This class is the small piece the views need between that stream and
 * their own `-reloadData`: the stream's callback runs on ITS OWN READER THREAD — `libagora-watch` says so plainly and
 * offers no run-loop scheduling yet — and AppKit may only be touched from the main thread. So the callback does the one
 * thread-safe thing, raising a flag, and a repeating timer on the main run loop takes the flag and calls the target.
 *
 * **A COALESCED "SOMETHING CHANGED" IS THE WHOLE CONTRACT.** The granular item flags exist, but a window's answer to
 * all of them is the same: read the directory again. Passing the paths on would invite a second, partial look at the
 * same directory — exactly the sort of half-updated view this class exists to remove.
 */
#ifndef WORKSPACE_WSDIRECTORYWATCHER_H
#define WORKSPACE_WSDIRECTORYWATCHER_H

#import <Foundation/NSObject.h>

#include <Watch/EventStream.h>

@class NSString;

@interface WSDirectoryWatcher : NSObject
{
	NSString *_directory;		/* RETAINED: what is being watched */
	FSEventStreamRef _stream;	/* the kernel's own stream; NULL once started or never created */
	int *_changed;			/* MALLOC'D: raised on the stream's thread, taken on the main one */
	id _target;			/* NOT RETAINED: the view or controller that wants to know */
	SEL _action;
	id _timer;			/* RETAINED: the main thread's drain */
}

/* The action is sent to `target` on the MAIN thread, with this watcher as its argument, whenever the stream has
 * reported a change since the last drain. A directory that cannot be watched (a path that is not there, no kernel
 * support) still answers an object: a missing ear is not an error, it is a window that behaves as it did before. */
- (instancetype)initWithDirectory:(NSString *)directory target:(id)target action:(SEL)action;

- (void)invalidate;
- (nullable NSString *)directory;

/* **THE SEAM, AND ALSO THE TIMER'S OWN DOOR.** The timer calls this; a probe calls it too, because a headless test has
 * no run loop to turn. */
- (void)cg_drain;

@end

#endif /* WORKSPACE_WSDIRECTORYWATCHER_H */
