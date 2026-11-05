using Ryujinx.Graphics.Shader.IntermediateRepresentation;
using Ryujinx.Graphics.Shader.StructuredIr;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;

namespace Ryujinx.Graphics.Shader.Translation.Optimizations
{
    static class Optimizer
    {
        public static void RunPass(TransformContext context)
        {
            for (int blkIndex = 0; blkIndex < context.Blocks.Length; blkIndex++)
            {
                XmadOptimizer.RunPass(context.Blocks[blkIndex]);
            }

            RunOptimizationPasses(context.Blocks, context.ResourceManager);

            // TODO: Some of those are not optimizations and shouldn't be here.

            GlobalToStorage.RunPass(context.Hfm, context.Blocks, context.ResourceManager, context.GpuAccessor, context.TargetLanguage);

            bool hostSupportsShaderFloat64 = context.GpuAccessor.QueryHostSupportsShaderFloat64();

            // Those passes are looking for specific patterns and only needs to run once.
            for (int blkIndex = 0; blkIndex < context.Blocks.Length; blkIndex++)
            {
                if (context.TargetApi == TargetApi.OpenGL)
                {
                    BindlessToArray.RunPassOgl(context.Blocks[blkIndex], context.ResourceManager);
                }
                else
                {
                    BindlessToArray.RunPass(context.Blocks[blkIndex], context.ResourceManager, context.GpuAccessor);
                }

                BindlessElimination.RunPass(context.Blocks[blkIndex], context.ResourceManager, context.GpuAccessor, deferSeveral: true);

                // FragmentCoord only exists on fragment shaders, so we don't need to check other stages.
                if (context.Stage == ShaderStage.Fragment)
                {
                    EliminateMultiplyByFragmentCoordW(context.Blocks[blkIndex]);
                }

                // If the host does not support double operations, we need to turn them into float operations.
                if (!hostSupportsShaderFloat64)
                {
                    DoubleToFloat.RunPass(context.Hfm, context.Blocks[blkIndex]);
                }
            }

            // nxnative: the reads whose handle merges several c[2] handles, once every other read has registered its texture (BindlessElimination.TryTableHandle)
            for (int blkIndex = 0; blkIndex < context.Blocks.Length; blkIndex++)
            {
                BindlessElimination.RunPass(context.Blocks[blkIndex], context.ResourceManager, context.GpuAccessor);
            }

            // Run optimizations one last time to remove any code that is now optimizable after above passes.
            RunOptimizationPasses(context.Blocks, context.ResourceManager);
        }

        private static void RunOptimizationPasses(BasicBlock[] blocks, ResourceManager resourceManager)
        {
            bool modified;

            do
            {
                modified = false;

                for (int blkIndex = 0; blkIndex < blocks.Length; blkIndex++)
                {
                    BasicBlock block = blocks[blkIndex];

                    LinkedListNode<INode> node = block.Operations.First;

                    while (node != null)
                    {
                        LinkedListNode<INode> nextNode = node.Next;

                        bool isUnused = IsUnused(node.Value);

                        if (node.Value is not Operation operation || isUnused)
                        {
                            if (node.Value is PhiNode phi && !isUnused)
                            {
                                isUnused = PropagatePhi(phi);
                            }

                            if (isUnused)
                            {
                                RemoveNode(block, node);

                                modified = true;
                            }

                            node = nextNode;

                            continue;
                        }

                        ConstantFolding.RunPass(resourceManager, operation);
                        Simplification.RunPass(operation);

                        if (DestIsLocalVar(operation))
                        {
                            if (operation.Inst == Instruction.Copy)
                            {
                                PropagateCopy(operation);

                                RemoveNode(block, node);

                                modified = true;
                            }
                            else if ((operation.Inst == Instruction.PackHalf2x16 && PropagatePack(operation)) ||
                                     (operation.Inst == Instruction.ShuffleXor && MatchDdxOrDdy(operation)))
                            {
                                if (DestHasNoUses(operation))
                                {
                                    RemoveNode(block, node);
                                }

                                modified = true;
                            }
                            else if (operation.Inst == Instruction.UnpackHalf2x16 && PropagateHalfword(node))
                            {
                                modified = true;
                            }
                        }

                        node = nextNode;
                    }

                    if (BranchElimination.RunPass(block))
                    {
                        RemoveNode(block, block.Operations.Last);

                        modified = true;
                    }
                }
            }
            while (modified);
        }

        private static void PropagateCopy(Operation copyOp)
        {
            // Propagate copy source operand to all uses of
            // the destination operand.

            Operand dest = copyOp.Dest;
            Operand src = copyOp.GetSource(0);

            INode[] uses = dest.UseOps.ToArray();

            foreach (INode useNode in uses)
            {
                for (int index = 0; index < useNode.SourcesCount; index++)
                {
                    if (useNode.GetSource(index) == dest)
                    {
                        useNode.SetSource(index, src);
                    }
                }
            }
        }

        private static bool PropagatePhi(PhiNode phi)
        {
            // If all phi sources are the same, we can propagate it and remove the phi.

            if (!Utils.AreAllSourcesTheSameOperand(phi))
            {
                return false;
            }

            // All sources are equal, we can propagate the value.

            Operand firstSrc = phi.GetSource(0);
            Operand dest = phi.Dest;

            INode[] uses = dest.UseOps.ToArray();

            foreach (INode useNode in uses)
            {
                for (int index = 0; index < useNode.SourcesCount; index++)
                {
                    if (useNode.GetSource(index) == dest)
                    {
                        useNode.SetSource(index, firstSrc);
                    }
                }
            }

            return true;
        }

        private static bool PropagatePack(Operation packOp)
        {
            // Propagate pack source operands to uses by unpack
            // instruction. The source depends on the unpack instruction.
            bool modified = false;

            Operand dest = packOp.Dest;
            Operand src0 = packOp.GetSource(0);
            Operand src1 = packOp.GetSource(1);

            INode[] uses = dest.UseOps.ToArray();

            foreach (INode useNode in uses)
            {
                if (useNode is not Operation operation || operation.Inst != Instruction.UnpackHalf2x16 || operation.ForcePrecise)
                {
                    continue;
                }

                if (operation.GetSource(0) == dest)
                {
                    operation.TurnIntoCopy(operation.Index == 1 ? src1 : src0);

                    modified = true;
                }
            }

            return modified;
        }

        // nxnative: an unpack of a word built from halfwords of other words (the halfword PRMTs, made explicit by InstEmitAmpereAlu.APrmtConstant: & 0xffff, & 0xffff0000,
        // << 16, >> 16 and |) reads the halfword it takes from the word that holds it. The bits are the same, so the result is too. The new unpack is marked precise:
        // PropagatePack must not take it on to the float a pack rounded to half (Pokemon Pokopia's 8743dd823fc8e863 rebuilds half pairs so 110 times)
        private static bool PropagateHalfword(LinkedListNode<INode> node)
        {
            Operation unpack = (Operation)node.Value;
            Operand source = unpack.GetSource(0);
            (Operand word, int half) = HalfwordSource(source, unpack.Index, 0);

            if (word == source && half == unpack.Index)
            {
                return false;
            }

            if (word == null)
            {
                unpack.TurnIntoCopy(OperandHelper.ConstF(0f));

                return true;
            }

            Operation redirected = new(Instruction.UnpackHalf2x16, half, unpack.Dest, word)
            {
                ForcePrecise = true,
            };

            node.List.AddBefore(node, redirected);
            Utils.DeleteNode(node, unpack);

            return true;
        }

        // The word and the halfword of it whose bits halfword `half` of `value` has; a null word when they are all zero
        private static (Operand, int) HalfwordSource(Operand value, int half, int depth)
        {
            if (value.Type == OperandType.Constant && (value.Value >> (half * 16) & 0xffff) == 0)
            {
                return (null, half);
            }

            if (depth == 8 || value.AsgOp is not Operation operation || operation.SourcesCount != 2)
            {
                return (value, half);
            }

            Operand a = operation.GetSource(0);
            Operand b = operation.GetSource(1);

            switch (operation.Inst)
            {
                case Instruction.BitwiseAnd when b.Type == OperandType.Constant && (b.Value == 0xffff || b.Value == unchecked((int)0xffff0000)):
                    return (b.Value == 0xffff) == (half == 0) ? HalfwordSource(a, half, depth + 1) : (null, half);
                case Instruction.ShiftLeft when b.Type == OperandType.Constant && b.Value == 16:
                    return half == 1 ? HalfwordSource(a, 0, depth + 1) : (null, half);
                case Instruction.ShiftRightU32 when b.Type == OperandType.Constant && b.Value == 16:
                    return half == 0 ? HalfwordSource(a, 1, depth + 1) : (null, half);
                case Instruction.BitwiseOr:
                    (Operand, int) fromA = HalfwordSource(a, half, depth + 1);
                    (Operand, int) fromB = HalfwordSource(b, half, depth + 1);

                    return fromA.Item1 == null ? fromB : fromB.Item1 == null ? fromA : (value, half);
            }

            return (value, half);
        }

        // nxnative: shared memory past the host's threadgroup memory (ResourceManager.HostSharedMemorySize) that every invocation addresses as S words of its own, local
        // invocation index * S + c with 0 <= c < S, in a program without barriers or atomics, becomes S words of private memory at c: no other invocation reads them.
        // Pokemon Pokopia's froxel lighting kernels (8 x 8 x 4 invocations of 37 or 47 words, 37,888 and 48,128 bytes) had no pipeline on an Apple GPU before
        public static void PrivatizeSharedMemory(IReadOnlyList<Function> functions, ResourceManager resourceManager, ShaderDefinitions definitions)
        {
            int id = resourceManager.SharedMemoryId;
            int[] size = [definitions.ComputeLocalSizeX, definitions.ComputeLocalSizeY, definitions.ComputeLocalSizeZ];

            if (definitions.Stage != ShaderStage.Compute || id < 0 || resourceManager.SharedMemorySize <= ResourceManager.HostSharedMemorySize || size[0] * size[1] * size[2] < 2)
            {
                return;
            }

            long[] unit = [size[0] > 1 ? 1 : 0, size[1] > 1 ? size[0] : 0, size[2] > 1 ? size[0] * size[1] : 0];
            List<(LinkedListNode<INode>, int)> accesses = [];
            long stride = 0;

            foreach (Function function in functions)
            {
                foreach (BasicBlock block in function.Blocks)
                {
                    for (LinkedListNode<INode> node = block.Operations.First; node != null; node = node.Next)
                    {
                        if (node.Value is not Operation operation)
                        {
                            continue;
                        }

                        if (operation.Inst is Instruction.Barrier or Instruction.SubgroupBarrier or Instruction.MemoryBarrier or Instruction.GroupMemoryBarrier)
                        {
                            return;
                        }

                        if (operation.StorageKind != StorageKind.SharedMemory || operation.GetSource(0).Value != id)
                        {
                            continue;
                        }

                        long[] form = operation.Inst is Instruction.Load or Instruction.Store ? LinearInThreadId(operation.GetSource(1), size, 0) : null;
                        long s = form == null ? 0 : unit[0] != 0 ? form[0] : unit[1] != 0 ? form[1] : form[2];

                        if (s <= 0 || (stride != 0 && s != stride) || form[0] != s * unit[0] || form[1] != s * unit[1] || form[2] != s * unit[2] || form[3] < 0 || form[3] >= s)
                        {
                            return;
                        }

                        stride = s;
                        accesses.Add((node, (int)form[3]));
                    }
                }
            }

            if (accesses.Count == 0 || stride * size[0] * size[1] * size[2] > resourceManager.Properties.SharedMemories[id].ArrayLength)
            {
                return;
            }

            int privateId = resourceManager.Properties.AddLocalMemory(new MemoryDefinition("shared_private", AggregateType.Array | AggregateType.U32, (int)stride));

            foreach ((LinkedListNode<INode> node, int offset) in accesses)
            {
                Operation access = (Operation)node.Value;
                Operation replacement = access.Inst == Instruction.Load
                    ? new(Instruction.Load, StorageKind.LocalMemory, access.Dest, OperandHelper.Const(privateId), OperandHelper.Const(offset))
                    : new(Instruction.Store, StorageKind.LocalMemory, null, OperandHelper.Const(privateId), OperandHelper.Const(offset), access.GetSource(2));

                node.List.AddBefore(node, replacement);
                Utils.DeleteNode(node, access);
            }

            resourceManager.RemoveCurrentSharedMemory();
        }

        // The value as x c[0] + y c[1] + z c[2] + c[3] over the local invocation ID, a component the workgroup does not span being 0; null for any other form, or one
        // whose 32-bit arithmetic could wrap
        private static long[] LinearInThreadId(Operand value, int[] size, int depth)
        {
            if (value.Type == OperandType.Constant)
            {
                return [0, 0, 0, value.Value];
            }

            if (depth == 16 || value.AsgOp is not Operation operation)
            {
                return null;
            }

            for (int k = 0; k < 3; k++)
            {
                if (Utils.IsInputLoad(operation, IoVariable.ThreadId, k))
                {
                    long[] component = [0, 0, 0, 0];
                    component[k] = size[k] > 1 ? 1 : 0;

                    return component;
                }
            }

            if (operation.Inst == Instruction.Copy)
            {
                return LinearInThreadId(operation.GetSource(0), size, depth + 1);
            }

            if (operation.SourcesCount != 2 || LinearInThreadId(operation.GetSource(0), size, depth + 1) is not long[] a || LinearInThreadId(operation.GetSource(1), size, depth + 1) is not long[] b)
            {
                return null;
            }

            bool bConstant = b[0] == 0 && b[1] == 0 && b[2] == 0;
            long[] result = operation.Inst switch
            {
                Instruction.Add => [a[0] + b[0], a[1] + b[1], a[2] + b[2], a[3] + b[3]],
                Instruction.Subtract => [a[0] - b[0], a[1] - b[1], a[2] - b[2], a[3] - b[3]],
                Instruction.Multiply when bConstant => [a[0] * b[3], a[1] * b[3], a[2] * b[3], a[3] * b[3]],
                Instruction.Multiply when a[0] == 0 && a[1] == 0 && a[2] == 0 => [b[0] * a[3], b[1] * a[3], b[2] * a[3], b[3] * a[3]],
                Instruction.ShiftLeft when bConstant && b[3] is >= 0 and < 31 => [a[0] << (int)b[3], a[1] << (int)b[3], a[2] << (int)b[3], a[3] << (int)b[3]],
                Instruction.ShiftRightU32 when bConstant && b[3] is >= 0 and < 31 && a.All(v => v >= 0 && v % (1L << (int)b[3]) == 0) => [a[0] >> (int)b[3], a[1] >> (int)b[3], a[2] >> (int)b[3], a[3] >> (int)b[3]],
                _ => null,
            };

            if (result == null || System.Math.Abs(result[0]) * size[0] + System.Math.Abs(result[1]) * size[1] + System.Math.Abs(result[2]) * size[2] + System.Math.Abs(result[3]) > int.MaxValue)
            {
                return null;
            }

            return result;
        }

        public static bool MatchDdxOrDdy(Operation operation)
        {
            // It's assumed that "operation.Inst" is ShuffleXor,
            // that should be checked before calling this method.
            Debug.Assert(operation.Inst == Instruction.ShuffleXor);

            bool modified = false;

            Operand src2 = operation.GetSource(1);
            Operand src3 = operation.GetSource(2);

            if (src2.Type != OperandType.Constant || (src2.Value != 1 && src2.Value != 2))
            {
                return false;
            }

            if (src3.Type != OperandType.Constant || src3.Value != 0x1c03)
            {
                return false;
            }

            bool isDdy = src2.Value == 2;
            bool isDdx = !isDdy;

            // We can replace any use by a FSWZADD with DDX/DDY, when
            // the following conditions are true:
            // - The mask should be 0b10100101 for DDY, or 0b10011001 for DDX.
            // - The first source operand must be the shuffle output.
            // - The second source operand must be the shuffle first source operand.
            INode[] uses = operation.Dest.UseOps.ToArray();

            foreach (INode use in uses)
            {
                if (use is not Operation test)
                {
                    continue;
                }

                if (use is not Operation useOp || useOp.Inst != Instruction.SwizzleAdd)
                {
                    continue;
                }

                Operand fswzaddSrc1 = useOp.GetSource(0);
                Operand fswzaddSrc2 = useOp.GetSource(1);
                Operand fswzaddSrc3 = useOp.GetSource(2);

                if (fswzaddSrc1 != operation.Dest)
                {
                    continue;
                }

                if (fswzaddSrc2 != operation.GetSource(0))
                {
                    continue;
                }

                if (fswzaddSrc3.Type != OperandType.Constant)
                {
                    continue;
                }

                int mask = fswzaddSrc3.Value;

                if ((isDdx && mask != 0b10011001) ||
                    (isDdy && mask != 0b10100101))
                {
                    continue;
                }

                useOp.TurnInto(isDdx ? Instruction.Ddx : Instruction.Ddy, fswzaddSrc2);

                modified = true;
            }

            return modified;
        }

        private static void EliminateMultiplyByFragmentCoordW(BasicBlock block)
        {
            foreach (INode node in block.Operations)
            {
                if (node is Operation operation)
                {
                    EliminateMultiplyByFragmentCoordW(operation);
                }
            }
        }

        private static void EliminateMultiplyByFragmentCoordW(Operation operation)
        {
            // We're looking for the pattern:
            //  y = x * gl_FragCoord.w
            //  v = y * (1.0 / gl_FragCoord.w)
            // Then we transform it into:
            //  v = x
            // This pattern is common on fragment shaders due to the way how perspective correction is done.

            // We are expecting a multiplication by the reciprocal of gl_FragCoord.w.
            if (operation.Inst != (Instruction.FP32 | Instruction.Multiply))
            {
                return;
            }

            Operand lhs = operation.GetSource(0);
            Operand rhs = operation.GetSource(1);

            // Check LHS of the main multiplication operation. We expect an input being multiplied by gl_FragCoord.w.
            if (lhs.AsgOp is not Operation attrMulOp || attrMulOp.Inst != (Instruction.FP32 | Instruction.Multiply))
            {
                return;
            }

            Operand attrMulLhs = attrMulOp.GetSource(0);
            Operand attrMulRhs = attrMulOp.GetSource(1);

            // LHS should be any input, RHS should be exactly gl_FragCoord.w.
            if (!Utils.IsInputLoad(attrMulLhs.AsgOp) || !Utils.IsInputLoad(attrMulRhs.AsgOp, IoVariable.FragmentCoord, 3))
            {
                return;
            }

            // RHS of the main multiplication should be a reciprocal operation (1.0 / x).
            if (rhs.AsgOp is not Operation reciprocalOp || reciprocalOp.Inst != (Instruction.FP32 | Instruction.Divide))
            {
                return;
            }

            Operand reciprocalLhs = reciprocalOp.GetSource(0);
            Operand reciprocalRhs = reciprocalOp.GetSource(1);

            // Check if the divisor is a constant equal to 1.0.
            if (reciprocalLhs.Type != OperandType.Constant || reciprocalLhs.AsFloat() != 1.0f)
            {
                return;
            }

            // Check if the dividend is gl_FragCoord.w.
            if (!Utils.IsInputLoad(reciprocalRhs.AsgOp, IoVariable.FragmentCoord, 3))
            {
                return;
            }

            // If everything matches, we can replace the operation with the input load result.
            operation.TurnIntoCopy(attrMulLhs);
        }

        public static void RemoveNode(BasicBlock block, LinkedListNode<INode> llNode)
        {
            // Remove a node from the nodes list, and also remove itself
            // from all the use lists on the operands that this node uses.
            block.Operations.Remove(llNode);

            Queue<INode> nodes = new();

            nodes.Enqueue(llNode.Value);

            while (nodes.TryDequeue(out INode node))
            {
                for (int index = 0; index < node.SourcesCount; index++)
                {
                    Operand src = node.GetSource(index);

                    if (src.Type != OperandType.LocalVariable)
                    {
                        continue;
                    }

                    if (src.UseOps.Remove(node) && src.UseOps.Count == 0)
                    {
                        Debug.Assert(src.AsgOp != null);

                        // nxnative (from MacNativeGames' translator patch 0002, after Ryujinx_Optime 01a1e37f): follow only into a producer that will be removed
                        // itself. One with side effects (an atomic, a call) stays in the block when its result is unused, so its sources are still live; dropping
                        // their uses here let the next dead-code pass delete the chain that feeds it, and the atomic then read undefined values.
                        if (!HasSideEffects(src.AsgOp) && DestHasNoUses(src.AsgOp))
                        {
                            nodes.Enqueue(src.AsgOp);
                        }
                    }
                }
            }
        }

        private static bool IsUnused(INode node)
        {
            return !HasSideEffects(node) && DestIsLocalVar(node) && DestHasNoUses(node);
        }

        private static bool HasSideEffects(INode node)
        {
            if (node is Operation operation)
            {
                switch (operation.Inst & Instruction.Mask)
                {
                    case Instruction.AtomicAdd:
                    case Instruction.AtomicAnd:
                    case Instruction.AtomicCompareAndSwap:
                    case Instruction.AtomicMaxS32:
                    case Instruction.AtomicMaxU32:
                    case Instruction.AtomicMinS32:
                    case Instruction.AtomicMinU32:
                    case Instruction.AtomicOr:
                    case Instruction.AtomicSwap:
                    case Instruction.AtomicXor:
                    case Instruction.Call:
                    case Instruction.ImageAtomic:
                        return true;
                }
            }

            return false;
        }

        private static bool DestIsLocalVar(INode node)
        {
            if (node.DestsCount == 0)
            {
                return false;
            }

            for (int index = 0; index < node.DestsCount; index++)
            {
                Operand dest = node.GetDest(index);

                if (dest != null && dest.Type != OperandType.LocalVariable)
                {
                    return false;
                }
            }

            return true;
        }

        private static bool DestHasNoUses(INode node)
        {
            for (int index = 0; index < node.DestsCount; index++)
            {
                Operand dest = node.GetDest(index);

                if (dest != null && dest.UseOps.Count != 0)
                {
                    return false;
                }
            }

            return true;
        }
    }
}
