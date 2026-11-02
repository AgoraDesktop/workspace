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

- (instancetype)initWithDirectory:(NSString *)directory target:(id)target action:(SEL)action
{
	self = [super init];
	if (self != nil && directory != nil && [directory length] > 0) {
		CFStringRef path = CFStringCreateWithCString(NULL, [directory UTF8String], kCFStringEncodingUTF8);
		FSEventStreamContext context = { 0 };
		const void *values[1];

		_directory = [directory copy];
		_target = target;
		_action = action;
		_changed = (int *)calloc(1, sizeof(int));
		if (path != NULL && _changed != NULL) {
			values[0] = path;
			{
				CFArrayRef paths = CFArrayCreate(NULL, values, 1, &kCFTypeArrayCallBacks);

				context.info = _changed;
				_stream = FSEventStreamCreate(NULL, fn_stream_changed, &context, paths,
							      kFSEventStreamEventIdSinceNow, WS_WATCH_LATENCY,
							      kFSEventStreamCreateFlagFileEvents);
				if (paths != NULL) {
					CFRelease(paths);
				}
			}
			CFRelease(path);
		} else if (path != NULL) {
			CFRelease(path);
		}
		if (_stream != NULL) {
			(void)FSEventStreamStart(_stream);
		}
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

- (NSString *)directory { return _directory; }

/* **ONE REFRESH PER BURST, ON THE MAIN THREAD.** The exchange is what makes a storm of changes — and the stream's own
 * reader thread — cost exactly one reload: whoever takes the 1 owns the notification. */
- (void)cg_drain
{
	if (_changed == NULL || __atomic_exchange_n(_changed, 0, __ATOMIC_RELAXED) == 0) {
		return;
	}
	if (_target != nil && _action != NULL && [_target respondsToSelector:_action]) {
		(void)[_target performSelector:_action withObject:self];
	}
}

@end
