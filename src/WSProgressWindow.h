/*
 * WSProgressWindow.h — what a file operation shows while it runs.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 *
 * A small floating window with a message and an `NSProgressIndicator`. The operation manager reports through a
 * handler and the controller feeds this window; the window itself knows nothing about files.
 */
#ifndef WORKSPACE_WSPROGRESSWINDOW_H
#define WORKSPACE_WSPROGRESSWINDOW_H

#import <AppKit/NSWindow.h>

@class NSProgressIndicator;
@class NSTextField;

@interface WSProgressWindow : NSWindow
{
	NSTextField *_message;
	NSProgressIndicator *_bar;
}
- (instancetype)init;
- (void)setMessage:(NSString *)message;
- (void)setCompleted:(NSUInteger)completed total:(NSUInteger)total path:(nullable NSString *)path;
- (void)show;
- (void)hide;
@end

#endif /* WORKSPACE_WSPROGRESSWINDOW_H */
