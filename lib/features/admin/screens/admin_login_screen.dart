import 'package:flutter/material.dart';
import '../../../core/database/database_service.dart';

class AdminLoginScreen extends StatefulWidget {
  const AdminLoginScreen({super.key});

  @override
  State<AdminLoginScreen> createState() => _AdminLoginScreenState();
}

class _AdminLoginScreenState extends State<AdminLoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  bool _obscurePassword = true;
  String? _errorMessage;
  bool _isLockedOut = false;

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final result = await DatabaseService.instance.validateAdmin(
        _usernameController.text.trim(),
        _passwordController.text,   // No .trim() — spaces in passwords are valid
      );

      if (!mounted) return;

      switch (result.status) {
        case AdminLoginStatus.success:
          Navigator.pushReplacementNamed(context, '/admin_dashboard');
          break;

        case AdminLoginStatus.lockedOut:
          setState(() {
            _isLockedOut = true;
            _errorMessage =
                'Account temporarily locked after too many failed attempts.\n'
                'Please try again in ${result.remainingMinutes} minutes.';
          });
          break;

        case AdminLoginStatus.failure:
          final remaining = result.attemptsRemaining;
          setState(() {
            _isLockedOut = false;
            _errorMessage = remaining != null && remaining > 0
                ? 'Invalid username or password. $remaining attempt${remaining == 1 ? '' : 's'} remaining before lockout.'
                : 'Invalid username or password.';
          });
          break;
      }
    } catch (e) {
      if (mounted) setState(() => _errorMessage = 'Login error. Please try again.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white70),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 20),
                Icon(
                  _isLockedOut
                      ? Icons.lock_rounded
                      : Icons.admin_panel_settings_rounded,
                  color: _isLockedOut ? Colors.redAccent : Colors.tealAccent,
                  size: 64,
                ),
                const SizedBox(height: 24),
                const Text(
                  'Administrator Access',
                  style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Enter your credentials to manage the system.',
                  style: TextStyle(color: Colors.white38, fontSize: 16),
                ),
                const SizedBox(height: 48),

                // Username
                _buildFieldLabel('Username'),
                TextFormField(
                  controller: _usernameController,
                  style: const TextStyle(color: Colors.white),
                  enabled: !_isLockedOut,
                  decoration: _buildInputDecoration('Enter username', Icons.person_outline),
                  validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 24),

                // Password
                _buildFieldLabel('Password'),
                TextFormField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  style: const TextStyle(color: Colors.white),
                  enabled: !_isLockedOut,
                  decoration: _buildInputDecoration(
                    'Enter password',
                    Icons.lock_outline,
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword ? Icons.visibility_off : Icons.visibility,
                        color: Colors.white38,
                      ),
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
                ),

                if (_errorMessage != null) ...[
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          _isLockedOut ? Icons.lock_rounded : Icons.error_outline,
                          color: Colors.redAccent,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(color: Colors.redAccent, fontSize: 14),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 48),

                SizedBox(
                  width: double.infinity,
                  height: 64,
                  child: ElevatedButton(
                    onPressed: _isLoading || _isLockedOut ? null : _login,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isLockedOut ? Colors.grey[800] : Colors.teal,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      elevation: 8,
                      shadowColor: Colors.teal.withOpacity(0.3),
                    ),
                    child: _isLoading
                        ? const CircularProgressIndicator(color: Colors.white)
                        : Text(
                            _isLockedOut ? 'Account Locked' : 'Login',
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFieldLabel(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Text(label,
          style: const TextStyle(
              color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600)),
    );
  }

  InputDecoration _buildInputDecoration(String hint, IconData icon,
      {Widget? suffixIcon}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white24),
      prefixIcon: Icon(icon, color: Colors.tealAccent.withOpacity(0.5), size: 22),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: Colors.white.withOpacity(0.05),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Colors.teal, width: 1.5)),
      contentPadding:
          const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
    );
  }
}
