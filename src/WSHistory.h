/*
 * WSHistory.h — where a file window has been, and the two arrows that go back and forward.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 *
 * **THE HISTORY IS SEPARATE FROM THE VIEW AND FROM THE MODEL, WHICH IS WHY IT CAN BE MEASURED WITHOUT EITHER.**
 * It is the same rule `WSIconLayout` follows: the interesting part of Back and Forward is not a button, it is the
 * stack discipline — where the cursor sits, what a Back does to Forward's possibility, and what a NEW navigation
 * does to the forward entries. `tests/history.m` asks those questions directly.
 *
 * **A NEW NAVIGATION TRUNCATES THE FORWARD STACK.** That is the reference file manager's behaviour and the reason
 * the stack is not a ring: after going back twice, opening a new folder abandons what was forward. A push of the
 * CURRENT location is a no-op, so a reload or a double-click on the folder already open does not grow the history.
 */
#ifndef WORKSPACE_WSHISTORY_H
#define WORKSPACE_WSHISTORY_H

#import <Foundation/NSArray.h>
#import <Foundation/NSObject.h>

@class NSArray;
@class NSURL;

@interface WSHistory : NSObject
{
	NSMutableArray *_urls;		/* RETAINED: NSURL, oldest first */
	NSInteger _index;		/* the current entry, always in range once there is one */
}
- (instancetype)initWithURL:(NSURL *)url;

- (nullable NSURL *)currentURL;
- (nullable NSURL *)backURL;
- (nullable NSURL *)forwardURL;

/* Add a location as the new current one, dropping everything after it. The current location is a no-op. */
- (void)pushURL:(NSURL *)url;

/* Move the cursor and answer whether it moved. */
- (BOOL)goBack;
- (BOOL)goForward;

- (BOOL)canGoBack;
- (BOOL)canGoForward;

/* THE WHOLE STACK AND THE CURSOR, for a probe and for a future history menu. */
- (NSArray *)URLs;
- (NSInteger)currentIndex;

@end

#endif /* WORKSPACE_WSHISTORY_H */
