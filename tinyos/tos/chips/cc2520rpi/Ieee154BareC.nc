
/* Provides an abstraction layer for complete access to an 802.15.4 packet
 * buffer. Packets provided to this module will be interpreted as 802.15.4
 * frames and will have the sequence number set. All other fields must be set
 * by upper layers.
 */

configuration Ieee154BareC {
  provides {
    interface SplitControl;

    interface Packet as BarePacket;
    interface Send as BareSend;
    interface Receive as BareReceive;
  }
}

implementation {
  components CC2520RpiRadioC;

  SplitControl = CC2520RpiRadioC.SplitControl;

  BarePacket = CC2520RpiRadioC.Packet;
  BareSend = CC2520RpiRadioC.Send;
  BareReceive = CC2520RpiRadioC.Receive;
}
