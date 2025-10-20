import 'package:dactor/dactor.dart';
import 'package:libspiffy/libspiffy.dart';

/// Demonstrates how to integrate LibSpiffy into a host application's actor system
/// 
/// This example shows:
/// 1. Creating a host application with its own actor system
/// 2. Integrating LibSpiffy into that system
/// 3. Creating custom actors that interact with LibSpiffy actors
/// 4. Proper lifecycle management

void main() async {
  print('=== LibSpiffy Actor System Integration Example ===\n');

  // Step 1: Create host application's actor system
  print('1. Creating host application actor system...');
  final hostActorSystem = LocalActorSystem(ActorSystemConfig());
  print('   ✓ Host actor system created\n');

  // Step 2: Initialize LibSpiffy with the host's actor system
  print('2. Integrating LibSpiffy into host actor system...');
  await initializeLibSpiffy(
    actorSystem: hostActorSystem, // Key: Share the actor system!
    dataDirectory: './example-data',
  );
  
  // Verify integration
  final libspiffy = getLibSpiffySystem();
  print('   ✓ LibSpiffy initialized');
  print('   ✓ Owns actor system: ${libspiffy.ownsActorSystem}'); // Should be false
  print('   ✓ All actors in same system: ${identical(hostActorSystem, libspiffy.actorSystem)}\n');

  // Step 3: Spawn a custom host actor that interacts with LibSpiffy
  print('3. Creating custom payment processor actor...');
  final paymentProcessor = await hostActorSystem.spawn(
    'payment-processor',
    () => PaymentProcessorActor(
      walletManager: libspiffy.walletManager,
      invoiceManager: libspiffy.invoiceManager,
      spvActor: libspiffy.spvActor,
    ),
  );
  print('   ✓ Custom actor spawned and wired to LibSpiffy actors\n');

  // Step 4: Demonstrate cross-actor communication
  print('4. Demonstrating unified actor system benefits...');
  
  // Create a receiver actor to get responses
  final receiver = await hostActorSystem.spawn(
    'response-receiver',
    () => ResponseReceiverActor(),
  );

  // Send a payment processing request through our custom actor
  paymentProcessor.tell(
    ProcessPaymentMessage(
      walletId: 'merchant-wallet',
      amount: BigInt.from(100000),
      description: 'Test payment',
    ),
    sender: receiver,
  );

  // Wait a moment for processing
  await Future.delayed(Duration(seconds: 1));
  print('   ✓ Messages flowing through unified actor system\n');

  // Step 5: Demonstrate supervision and monitoring
  print('5. Actor system statistics:');
  print('   • All actors supervised by single system');
  print('   • Single message dispatcher');
  print('   • Unified failure isolation\n');

  // Step 6: Clean shutdown
  print('6. Shutting down...');
  
  // LibSpiffy shutdown only closes its resources, not the host's actor system
  await shutdownLibSpiffy();
  print('   ✓ LibSpiffy resources closed');
  print('   ✓ Host actor system still running (not shut down by LibSpiffy)');
  
  // Host manages its own actor system lifecycle
  await hostActorSystem.shutdown();
  print('   ✓ Host actor system shut down\n');

  print('=== Example Complete ===');
  print('\nKey Takeaways:');
  print('• LibSpiffy actors integrate seamlessly into host system');
  print('• Single actor system = better performance and supervision');
  print('• Host retains full control over actor system lifecycle');
  print('• Custom actors can directly communicate with LibSpiffy actors');
}

/// Example custom actor that processes payments using LibSpiffy
class PaymentProcessorActor extends Actor {
  final ActorRef _walletManager;
  final ActorRef _invoiceManager;

  PaymentProcessorActor({
    required ActorRef walletManager,
    required ActorRef invoiceManager,
    required ActorRef spvActor, // Keep parameter for API consistency
  })  : _walletManager = walletManager,
        _invoiceManager = invoiceManager;

  @override
  Future<void> onMessage(dynamic message) async {
    if (message is ProcessPaymentMessage) {
      print('   → PaymentProcessor: Processing payment for ${message.walletId}');
      
      // 1. Ensure wallet exists (direct communication with LibSpiffy actor)
      _walletManager.tell(
        CreateWalletMessage(
          message.walletId,
          'Payment Wallet',
        ),
      );
      
      // 2. Create invoice (direct communication with LibSpiffy actor)
      _invoiceManager.tell(
        CreateInvoiceMessage(
          walletId: message.walletId,
          amount: message.amount,
          description: message.description,
        ),
        sender: context.sender, // Forward response to original sender
      );
      
      print('   → PaymentProcessor: Invoice creation initiated');
    }
  }
}

/// Example message for payment processing
class ProcessPaymentMessage implements Message {
  final String walletId;
  final BigInt amount;
  final String? description;

  ProcessPaymentMessage({
    required this.walletId,
    required this.amount,
    this.description,
  });

  @override
  String get correlationId => 'payment-${DateTime.now().millisecondsSinceEpoch}';

  @override
  Map<String, dynamic> get metadata => {
    'walletId': walletId,
    'amount': amount.toString(),
    if (description != null) 'description': description!,
  };

  @override
  ActorRef? get replyTo => null;

  @override
  DateTime get timestamp => DateTime.now();
}

/// Simple actor that receives and logs responses
class ResponseReceiverActor extends Actor {
  @override
  Future<void> onMessage(dynamic message) async {
    print('   ← Receiver: Got response: ${message.runtimeType}');
    if (message is InvoiceCreatedMessage) {
      if (message.success) {
        print('   ← Receiver: Invoice ${message.invoiceId} created successfully');
      } else {
        print('   ← Receiver: Invoice creation failed: ${message.error}');
      }
    }
  }
}

