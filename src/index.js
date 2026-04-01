require('dotenv').config();
const express = require('express');
const mongoose = require('mongoose');
const config = require('./config');
const todosRouter = require('./routes/todos');

const app = express();

app.use(express.json());

// Health check - verifies MongoDB connectivity
app.get('/health', async (req, res) => {
  try {
    if (mongoose.connection.readyState !== 1) {
      return res.status(503).json({ status: 'error', message: 'MongoDB not connected' });
    }
    // Use db.command() which works without admin privileges
    await mongoose.connection.db.command({ ping: 1 });
    res.json({ status: 'ok', mongo: 'connected' });
  } catch (err) {
    res.status(503).json({ status: 'error', message: 'MongoDB ping failed' });
  }
});

// Todo routes
app.use('/todos', todosRouter);

const start = async () => {
  try {
    await mongoose.connect(config.mongoUrl);
    console.log('Connected to MongoDB');
    app.listen(config.port, () => {
      console.log(`Server running on port ${config.port}`);
    });
  } catch (err) {
    console.error('Failed to connect to MongoDB:', err.message);
    process.exit(1);
  }
};

// Only start the server when run directly (not imported in tests)
if (require.main === module) {
  start();
}

module.exports = app;
module.exports.start = start;
