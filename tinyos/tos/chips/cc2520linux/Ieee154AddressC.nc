
/* Dummy module that gives a constant name (Ieee154AddressC) to the component
 * that handles ieee15.4 addresses.
 *
 * @author: Brad Campbell <bradjc@umich.edu>
 */

configuration Ieee154AddressC {
  provides {
  	interface Ieee154Address;
  }

} implementation {
  components RadioSelectC;
  Ieee154Address = RadioSelectC.Ieee154Address;
}
