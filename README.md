Shallow wrapper for bottlerocket libraries written for Chicken Scheme. For information about bottlerocket, please visit http://www.linuxha.com/bottlerocket. 

Always remember to specify the port first:
(br-x10-portname "/dev/ttySAC0")

You can control the verbosity:
(br-verbosity 1)

Now, you can start controlling devices:
(br-on "A1")

This library should support all main features available in Bottlerocket. 

Send hatemail to m dot gelman08 at gmail dot com.
