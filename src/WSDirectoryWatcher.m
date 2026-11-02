/*
 * WSDirectoryWatcher.m — the stream, its reader thread, and the main thread that hears about it.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#import "WSDirectoryWatcher.h"

#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/NSAutoreleasePool.h>
#import <Foundation/NSObject.h>
#import <Foundation/NSString.h>
#import <Foundation/NSTimer.h>

#include <stdlib.h>

/* **THE COALESCING WINDOW.** The stream already merges a burst of changes; this is how long it may hold them before
 * saying so. A tenth of a second is what makes a `cp -r` of a folder one refresh instead of forty, and it is short
 * enough that a person who made a folder in a terminal sees it before they look up. */
#define WS_WATCH_LATENCY 0.1

/* And how often the main thread looks at the flag the reader thread raises. It has to be a poll because this tier's
 * `libagora-watch` delivers on its own thread and has no run-loop scheduling yet; the timer's only work is one
 * atomic read while nothing has changed, which is why it can afford to be this frequent. */
#define WS_WATCH_TICK 0.1

/* THE READER THREAD'S WHOLE JOB: raise the flag this watcher was made with. `info` is the malloc'd int rather than the
 * object, so nothing here touches a reference count or an ivar from a thread that may not. */
static void fn_stream_changed(ConstFSEventStreamRef stream, void *info, size_t numEvents, void *eventPaths,
			      const FSEventStreamEventFlags eventFlags[], const FSEventStreamEventId eventIds[])
{
	(void)stream;
	(void)numEvents;
	(void)eventPaths;
	(void)eventFlags;
	(void)eventIds;
	__atomic_store_n((int *)info, 1, __ATOMIC_RELAXED);
}

@implementation WSDirectoryWatcher

/* THE STREAM, BUILT FROM WHATEVER PATHS THE WINDOW IS SHOWING.** A window shows its folder and whatever it has
 * expanded under it, so the watch is a LIST: one directory, or a folder and the three subtrees a person opened. Every
 * path is watched on its own and the stream is NON-RECURSIVE (`kFSEventStreamCreateFlagNoRecursive`), which is what
 * makes "the paths given" mean "the rows drawn" — no walk under a folder nobody expanded, and no freeze on a home
 * directory (180,865 directories against a 65,536-watch limit, measured). */
- (void)fn_openStream
{
	CFMutableArrayRef paths;
	FSEventStreamContext context = { 0 };
	NSUInteger i;

	if (_stream != NULL) {
		FSEventStreamStop(_stream);
		FSEventStreamInvalidate(_stream);
		FSEventStreamRelease(_stream);
		_stream = NULL;
	}
	if (_changed == NULL || [_paths count] == 0) {
		return;
	}
	paths = CFArrayCreateMutable(NULL, (CFIndex)[_paths count], &kCFTypeArrayCallBacks);
	if (paths == NULL) {
		return;
	}
	for (i = 0; i < [_paths count]; i++) {
		CFStringRef path = CFStringCreateWithCString(NULL, [[_paths objectAtIndex:i] UTF8String],
							     kCFStringEncodingUTF8);

		if (path != NULL) {
			CFArrayAppendValue(paths, path);
			CFRelease(path);
		}
	}
	context.info = _changed;
	_stream = FSEventStreamCreate(NULL, fn_stream_changed, &context, paths,
				      kFSEventStreamEventIdSinceNow, WS_WATCH_LATENCY,
				      kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoRecursive);
	CFRelease(paths);
	if (_stream != NULL) {
		(void)FSEventStreamStart(_stream);
	}
}

- (instancetype)initWithPaths:(NSArray *)paths target:(id)target action:(SEL)action
{
	self = [super init];
	if (self != nil) {
		_paths = [paths copy];
		_target = target;
		_action = action;
		_changed = (int *)calloc(1, sizeof(int));
		[self fn_openStream];
		/* **AND THE MAIN THREAD'S HALF IS A TIMER, WHICH IS ALSO WHAT MAKES THIS CLASS SURVIVE ITS OWN START.** A
		 * watcher with no stream (a directory that is not there) still gets its timer, so its owner has one object to
		 * keep and release rather than a nil to test at every turn. */
		_timer = [[NSTimer scheduledTimerWithTimeInterval:WS_WATCH_TICK
							  target:self
							selector:@selector(cg_drain)
							userInfo:nil
							 repeats:YES] retain];
	}
	return self;
}

- (instancetype)initWithDirectory:(NSString *)directory target:(id)target action:(SEL)action
{
	if (directory == nil || [directory length] == 0) {
		return [self initWithPaths:[NSArray array] target:target action:action];
	}
	return [self initWithPaths:[NSArray arrayWithObject:directory] target:target action:action];
}

- (void)dealloc
{
	[self invalidate];
	[super dealloc];
}

- (void)invalidate
{
	if (_timer != nil) {
		[_timer invalidate];
		[_timer release];
		_timer = nil;
	}
	if (_stream != NULL) {
		FSEventStreamStop(_stream);
		FSEventStreamInvalidate(_stream);
		FSEventStreamRelease(_stream);
		_stream = NULL;
	}
	/* THE FLAG IS FREED LAST, and only once the stream is gone: the reader thread may still be inside the callback
	 * until `FSEventStreamStop` has returned. */
	if (_changed != NULL) {
		free(_changed);
		_changed = NULL;
	}
	_target = nil;
	_action = NULL;
}

- (NSArray *)paths { return _paths; }
- (NSString *)directory { return ([_paths count] > 0) ? [_paths objectAtIndex:0] : nil; }

/* **A WINDOW THAT EXPANDS A FOLDER WATCHES IT TOO, AND ONE THAT COLLAPSES IT STOPS.** The list is replaced, and the
 * stream is rebuilt only when the list actually changed — expanding the same folder twice is not two streams. */
- (BOOL)setPaths:(NSArray *)paths
{
	NSArray *copy;

	if (paths == nil) {
		paths = [NSArray array];
	}
	if ([_paths isEqual:paths]) {
		return NO;
	}
	copy = [paths copy];
	[_paths release];
	_paths = copy;
	[self fn_openStream];
	return YES;
}

/* **ONE REFRESH PER BURST, ON THE MAIN THREAD.** The exchange is what makes a storm of changes — and the stream's own
 * reader thread — cost exactly one reload: whoever takes the 1 owns the notification. */
- (void)cg_drain
{
	if (_changed == NULL || __atomic_exchange_n(_changed, 0, __ATOMIC_RELAXED) == 0) {
		return;
	}
	if (_target != nil && _action != NULL && [_target respondsToSelector:_action]) {
		/* **THE TARGET MAY LET GO OF THIS WATCHER WHILE IT ANSWERS** — a refresh that navigates or changes the watched
		 * set replaces it — so the object is held across the call rather than used after its owner has dropped it. */
		[self retain];
		(void)[_target performSelector:_action withObject:self];
		[self release];
	}
}

@end
