//
//  SiriRemote-Bridging-Header.h
//  HyperVibe
//
//  Bridging header to expose MultitouchSupport private framework to Swift
//

#ifndef SiriRemote_Bridging_Header_h
#define SiriRemote_Bridging_Header_h

#import "MultitouchSupport.h"
#import "opus/opus.h"
#import <IOBluetooth/IOBluetooth.h>

// Informal / private delegate method used by InternalBlue-style HCI taps.
@protocol IOBluetoothHostControllerDelegate <NSObject>
@optional
- (void)BluetoothHCIEventNotificationMessage:(IOBluetoothHostController *)controller
                       inNotificationMessage:(void *)message;
@end

#endif /* SiriRemote_Bridging_Header_h */
