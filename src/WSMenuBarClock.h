/*
 * WSMenuBarClock.h — the time, in the menu bar, as an `NSStatusItem`.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Portions of this file may derive from GNUstep; see THIRD-PARTY.md.
 *
 * **WHY THIS EXISTS AT ALL, AND IT IS NOT ONLY BECAUSE A DESKTOP WANTS A CLOCK.** Everything else this shell owns is
 * a WINDOW: the desktop, a file window, a sheet, a panel. A status item is the one piece of an application that is
 * NOT a window in any sense the application can state — it has a length and no position, because an application does
 * not know what else is in the bar, so it cannot know where its own item goes (`NSStatusItem.h` says so at length).
 * The server packs the item from the right edge leftwards and the application draws into it. That arrangement had
 * never been driven end to end from this tree: `libagora-app`'s own probe makes an item and puts a coloured mark in
 * it, and nothing measured whether the mark reached the glass. A clock is the smallest thing that is genuinely useful
 * AND genuinely uses the door: it is a view the application draws, a width that CHANGES (the second digit arrives),
 * and a value that must be refreshed while the desktop sits still.
 *
 * **IT IS NOT THE MAC'S CLOCK AND DOES NOT CLAIM TO BE.** The reference system owns its clock: the whole bar is the
 * system's and clicking the time opens a notification centre this tree has no equivalent of. Here the bar is the
 * server's and what sits in it is the application's, which is the arrangement the protocol's `set_status_item`
 * states. So this clock is Workspace's, which for a shell is the right owner: it is on the strip whenever Workspace
 * is, whether or not Workspace has the keyboard — a clock that came and went with the active application would be a
 * window and not a clock.
 *
 * **A REFUSAL IS RECORDED RATHER THAN WORKED AROUND.** `-[NSStatusItem popUpStatusItemMenu:]` is a named refusal in
 * this tree (it needs the menu tracking session a dropdown's panel is), so this item has NO menu and its view does
 * nothing when it is clicked. A clock that offered a menu it could not track would be a bar that lies about what a
 * click will do; one that is simply a clock tells the truth.
 */
#ifndef WORKSPACE_WSMENUBARCLOCK_H
#define WORKSPACE_WSMENUBARCLOCK_H

#import <AppKit/NSView.h>
#import <Foundation/NSObject.h>

@class NSDate;
@class NSDateFormatter;
@class NSStatusItem;

/* ---------------------------------------------------------------------------------------------------
 * The view the item draws, which IS the width the item has.
 * ---------------------------------------------------------------------------------------------------
 *
 * **ITS WIDTH IS HALF OF THE CONTRACT, WHICH IS WHY THE CLASS IS NOT PRIVATE TO THE .m.** `NSVariableStatusItemLength`
 * is resolved by asking the view how wide it is, so "the item got wider when the time did" is a question about this
 * object and about nothing else an application can see. A caller never makes one — `WSMenuBarClock` does — but a probe
 * asks it things, and a `.m`-private class cannot be asked. */
@interface WSClockView : NSView
{
	NSString *_time;
}

/* The width an item showing `text` asks the server for: the measured line plus the air either side, rounded up
 * because the protocol's width is an integer. */
+ (CGFloat)widthForTimeString:(NSString *)text;

- (NSString *)timeString;
- (void)setTimeString:(NSString *)text;

@end

/* ---------------------------------------------------------------------------------------------------
 * The clock.
 * --------------------------------------------------------------------------------------------------- */

@interface WSMenuBarClock : NSObject
{
	NSStatusItem *_item;		/* RETAINED: it is in the bar's list, and this object is what puts it there */
	WSClockView *_view;		/* RETAINED: the item's content view, which is what draws the time */
	NSDateFormatter *_formatter;
	double _shownMinute;		/* which minute is on the glass, so a pass that changed nothing draws nothing */
	BOOL _observing;
}

/* **MAKE THE ITEM AND PUT IT IN THE BAR.** NO when there is no bar to put it in: `-thickness` answers 0 with no
 * window server to ask, and an item of no height is not a clock, it is a window nobody will ever see. A caller that
 * gets NO has a desktop without a clock, which is the honest state of a session with no compositor — but it still has
 * a clock that READS the time, because only the ITEM needs a bar and the measurement does not (`-timeString` answers
 * after a NO, and the offscreen suite relies on it). */
- (BOOL)start;

/* Take the item back out and stop watching the loop. Safe on a clock that never started, and it does not throw the
 * view or the formatter away: a `-start` after a `-stop` re-uses them. */
- (void)stop;

/* **THE ONE SEAM.** Put the time for `date` on the glass, measuring the item again if the string changed — which is
 * the whole of what "a status item's width is the application's to state" means in practice. It is a public door
 * rather than a private one because a probe can push a chosen moment through it and read the width back, and because a
 * clock whose only way to advance is the wall clock cannot be tested at a minute boundary at all. A `nil` date means
 * now. */
- (void)showTimeForDate:(NSDate *)date;

/* What the item currently says, which is what the strip should be showing. */
- (NSString *)timeString;

/* The item's view, for the width question the item's `-length` only answers on a machine with a bar. */
- (WSClockView *)view;

/* The item itself, for a caller that wants its length — the server's answer to "how wide am I allowed to be". Nil
 * without a bar. */
- (NSStatusItem *)statusItem;

@end

#endif /* WORKSPACE_WSMENUBARCLOCK_H */
